/*
 * Ультра-компрессор: ELF-ориентированный препроцессинг + LZMA2
 * Стратегия:
 * 1) Парсим ELF, находим секции кода (AX flags)
 * 2) ARM64 / x86_64 branch normalization (относительные -> абсолютные адреса)
 * 3) Byte-plane separation (stride=4) для инструкций ARM64
 * 4) Delta encoding
 * 5) LZMA2 сжатие с ДИНАМИЧЕСКИМ размером словаря
 * 6) Глубокий Brute-force оптимизатор с РЕГУЛИРУЕМЫМ УРОВНЕМ (0-3)
 * 7) МУЛЬТИПОТОЧНОСТЬ (OpenMP) для максимального ускорения упаковки
 *
 * Формат выходного файла:
 * [8 байт] magic "UCOMP01\0"
 * [8 байт] исходный размер файла (LE)
 * [4 байт] количество чанков (блоков)
 * На каждый чанк:
 * [1 байт]  тип препроцессинга
 * 0 = чистый LZMA2
 * 1 = chunk: arm64_planes + delta
 * 2 = chunk: delta_only
 * 3 = blob: branch_normalize (ARM64 или x86_64)
 * 4 = blob: branch_normalize + in-place planes + delta
 * 5 = blob: total_file_delta
 * 6 = blob: branch_normalize + total_file_delta
 * [4 байта] исходный размер чанка
 * [4 байта] сжатый размер чанка (включая 1 байт свойств LZMA2)
 * [1 байт]  байт свойств LZMA2 (закодированный размер словаря)
 * [сжатые данные LZMA2...]
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <sys/stat.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#include <Lzma2Enc.h>
#include <Lzma2Dec.h>
#include <Alloc.h>

typedef struct {
    uint8_t  e_ident[16];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
} Elf64_Ehdr;

typedef struct {
    uint32_t sh_name;
    uint32_t sh_type;
    uint64_t sh_flags;
    uint64_t sh_addr;
    uint64_t sh_offset;
    uint64_t sh_size;
    uint32_t sh_link;
    uint32_t sh_info;
    uint64_t sh_addralign;
    uint64_t sh_entsize;
} Elf64_Shdr;

#define SHF_EXECINSTR 0x4
#define EM_386        3
#define EM_X86_64     62
#define EM_AARCH64    183


static void arm64_branch_normalize(uint8_t *data, uint64_t size) {
    for (uint64_t i = 0; i + 3 < size; i += 4) {
        uint32_t instr = data[i] | (data[i+1] << 8) | (data[i+2] << 16) | ((uint32_t)data[i+3] << 24);
        uint32_t opcode_top = instr >> 26;
        uint32_t new_instr = instr;
        int modified = 0;
        
        if (opcode_top == 0x05 || opcode_top == 0x25) {
            int32_t imm26 = instr & 0x03FFFFFF;
            if (imm26 & 0x02000000) imm26 |= (int32_t)0xFC000000;
            uint32_t abs_addr = (uint32_t)((int32_t)(i / 4) + imm26);
            new_instr = (instr & 0xFC000000) | (abs_addr & 0x03FFFFFF);
            modified = 1;
        }
        else if ((instr & 0x9F000000) == 0x90000000) {
            int32_t immhi = (instr >> 5) & 0x7FFFF;
            int32_t immlo = (instr >> 29) & 0x3;
            int32_t imm21 = (immhi << 2) | immlo;
            if (imm21 & 0x100000) imm21 |= (int32_t)0xFFE00000;
            uint32_t page = (uint32_t)((int32_t)(i >> 12) + imm21);
            uint32_t new_immhi = (page >> 2) & 0x7FFFF;
            uint32_t new_immlo = page & 0x3;
            new_instr = (instr & 0x9F00001F) | (new_immhi << 5) | (new_immlo << 29);
            modified = 1;
        }
        
        if (modified) {
            data[i]   = new_instr & 0xFF;
            data[i+1] = (new_instr >> 8) & 0xFF;
            data[i+2] = (new_instr >> 16) & 0xFF;
            data[i+3] = (new_instr >> 24) & 0xFF;
        }
    }
}

static void arm64_branch_denormalize(uint8_t *data, uint64_t size) {
    for (uint64_t i = 0; i + 3 < size; i += 4) {
        uint32_t instr = data[i] | (data[i+1] << 8) | (data[i+2] << 16) | ((uint32_t)data[i+3] << 24);
        uint32_t opcode_top = instr >> 26;
        uint32_t new_instr = instr;
        int modified = 0;
        
        if (opcode_top == 0x05 || opcode_top == 0x25) {
            uint32_t abs_addr = instr & 0x03FFFFFF;
            if (abs_addr & 0x02000000) abs_addr |= 0xFC000000;
            int32_t rel = (int32_t)abs_addr - (int32_t)(i / 4);
            new_instr = (instr & 0xFC000000) | ((uint32_t)rel & 0x03FFFFFF);
            modified = 1;
        }
        else if ((instr & 0x9F000000) == 0x90000000) {
            uint32_t immhi = (instr >> 5) & 0x7FFFF;
            uint32_t immlo = (instr >> 29) & 0x3;
            uint32_t page = (immhi << 2) | immlo;
            if (page & 0x100000) page |= 0xFFE00000;
            int32_t rel = (int32_t)page - (int32_t)(i >> 12);
            uint32_t new_immhi = ((uint32_t)rel >> 2) & 0x7FFFF;
            uint32_t new_immlo = (uint32_t)rel & 0x3;
            new_instr = (instr & 0x9F00001F) | (new_immhi << 5) | (new_immlo << 29);
            modified = 1;
        }
        
        if (modified) {
            data[i]   = new_instr & 0xFF;
            data[i+1] = (new_instr >> 8) & 0xFF;
            data[i+2] = (new_instr >> 16) & 0xFF;
            data[i+3] = (new_instr >> 24) & 0xFF;
        }
    }
}

static uint8_t* arm64_planes_encode(const uint8_t *data, uint64_t size) {
    uint8_t *out = malloc(size);
    if (!out) return NULL;
    uint64_t n_instr = size / 4;
    uint64_t remainder = size % 4;
    #pragma omp simd
    for (uint64_t i = 0; i < n_instr; i++) {
        out[i]              = data[i*4 + 3];
        out[n_instr + i]    = data[i*4 + 2]; 
        out[2*n_instr + i]  = data[i*4 + 1];
        out[3*n_instr + i]  = data[i*4 + 0];
    }
    for (uint64_t i = 0; i < remainder; i++) out[4*n_instr + i] = data[n_instr*4 + i];
    return out;
}

static uint8_t* arm64_planes_decode(const uint8_t *data, uint64_t size) {
    uint8_t *out = malloc(size);
    if (!out) return NULL;
    uint64_t n_instr = size / 4;
    uint64_t remainder = size % 4;
    #pragma omp simd
    for (uint64_t i = 0; i < n_instr; i++) {
        out[i*4 + 3] = data[i];
        out[i*4 + 2] = data[n_instr + i];
        out[i*4 + 1] = data[2*n_instr + i];
        out[i*4 + 0] = data[3*n_instr + i];
    }
    for (uint64_t i = 0; i < remainder; i++) out[n_instr*4 + i] = data[4*n_instr + i];
    return out;
}


static void x86_branch_normalize(uint8_t *data, uint64_t size) {
    for (uint64_t i = 0; i + 5 <= size; i++) {
        if (data[i] == 0xE8 || data[i] == 0xE9) {
            uint32_t rel = data[i+1] | (data[i+2] << 8) | (data[i+3] << 16) | ((uint32_t)data[i+4] << 24);
            uint32_t abs_addr = rel + (uint32_t)(i + 5);
            data[i+1] = abs_addr & 0xFF;
            data[i+2] = (abs_addr >> 8) & 0xFF;
            data[i+3] = (abs_addr >> 16) & 0xFF;
            data[i+4] = (abs_addr >> 24) & 0xFF;
            i += 4; 
        }
    }
}

static void x86_branch_denormalize(uint8_t *data, uint64_t size) {
    for (uint64_t i = 0; i + 5 <= size; i++) {
        if (data[i] == 0xE8 || data[i] == 0xE9) {
            uint32_t abs_addr = data[i+1] | (data[i+2] << 8) | (data[i+3] << 16) | ((uint32_t)data[i+4] << 24);
            uint32_t rel = abs_addr - (uint32_t)(i + 5);
            data[i+1] = rel & 0xFF;
            data[i+2] = (rel >> 8) & 0xFF;
            data[i+3] = (rel >> 16) & 0xFF;
            data[i+4] = (rel >> 24) & 0xFF;
            i += 4;
        }
    }
}

static void delta_encode(uint8_t *data, uint64_t size) {
    if (size < 2) return;
    for (uint64_t i = size - 1; i >= 1; i--) data[i] = data[i] - data[i-1];
}

static void delta_decode(uint8_t *data, uint64_t size) {
    for (uint64_t i = 1; i < size; i++) data[i] = data[i] + data[i-1];
}


static uint32_t get_optimal_dict_size(size_t in_size, int opt_level) {
    uint32_t dict_size = 4096;
    uint32_t max_dict = (opt_level >= 3) ? (32 * 1024 * 1024) : (16 * 1024 * 1024);
    while (dict_size < in_size && dict_size < max_dict) {
        dict_size <<= 1;
    }
    return dict_size;
}

static uint8_t* lzma_compress_buf(const uint8_t *in, size_t in_size, size_t *out_size, int lc, int lp, int pb, int opt_level) {
    CLzma2EncHandle enc = Lzma2Enc_Create(&g_Alloc, &g_BigAlloc);
    if (!enc) return NULL;

    CLzma2EncProps props;
    Lzma2EncProps_Init(&props);
    props.lzmaProps.level = 9;
    props.lzmaProps.dictSize = get_optimal_dict_size(in_size, opt_level);
    
    props.lzmaProps.lc = lc;
    props.lzmaProps.lp = lp;
    props.lzmaProps.pb = pb;
    props.lzmaProps.fb = 273;
    
    if (opt_level == 0) props.lzmaProps.mc = 48;
    else if (opt_level == 1) props.lzmaProps.mc = 256;
    else if (opt_level == 2) props.lzmaProps.mc = 4096;
    else props.lzmaProps.mc = 500000;
    
    props.lzmaProps.algo = 1;
    props.lzmaProps.btMode = 1;
    props.lzmaProps.numHashBytes = 4;
    props.blockSize = LZMA2_ENC_PROPS__BLOCK_SIZE__SOLID;
    props.numTotalThreads = 1;

    if (Lzma2Enc_SetProps(enc, &props) != SZ_OK) {
        Lzma2Enc_Destroy(enc);
        return NULL;
    }

    Byte prop_byte = Lzma2Enc_WriteProperties(enc);

    size_t alloc_size = in_size + in_size / 10 + 4096;
    uint8_t *out = malloc(1 + alloc_size);
    if (!out) { Lzma2Enc_Destroy(enc); return NULL; }

    out[0] = prop_byte;
    size_t comp_size = alloc_size;

    SRes res = Lzma2Enc_Encode2(enc, NULL, out + 1, &comp_size, NULL, in, in_size, NULL);
    Lzma2Enc_Destroy(enc);

    if (res != SZ_OK) {
        free(out);
        return NULL;
    }

    *out_size = 1 + comp_size;
    return out;
}

static uint8_t* lzma_decompress_buf(const uint8_t *in, size_t in_size, size_t orig_size) {
    if (in_size < 1) return NULL;
    
    if (orig_size > (256 * 1024 * 1024)) {
        fprintf(stderr, "[!] Ошибка: Требуется слишком много памяти.\n");
        return NULL;
    }

    Byte prop = in[0];
    const Byte *comp_data = in + 1;
    SizeT comp_len = (SizeT)(in_size - 1);

    uint8_t *out = malloc(orig_size);
    if (!out) return NULL;

    SizeT dest_len = (SizeT)orig_size;
    ELzmaStatus status;

    SRes res = Lzma2Decode(out, &dest_len, comp_data, &comp_len,
                            prop, LZMA_FINISH_END, &status, &g_Alloc);

    if (res != SZ_OK || dest_len != orig_size) {
        free(out);
        return NULL;
    }
    return out;
}

typedef struct {
    uint8_t  preproc_type; 
    uint8_t *compressed;
    size_t   comp_size;
    size_t   orig_size;
} ChunkResult;

static ChunkResult compress_chunk_best(uint8_t *data, size_t size, int is_code, int arch_type, int opt_level) {
    ChunkResult best = {0, NULL, 0, size};
    best.comp_size = (size_t)-1;
    
    {
        size_t cs;
        uint8_t *c = lzma_compress_buf(data, size, &cs, 3, 0, 2, opt_level);
        if (c && cs < best.comp_size) {
            free(best.compressed); best.compressed = c; best.comp_size = cs; best.preproc_type = 0;
        } else { free(c); }
    }
    
    if (opt_level == 0) return best;
    
    {
        size_t cs;
        uint8_t *c = lzma_compress_buf(data, size, &cs, 2, 2, 2, opt_level);
        if (c && cs < best.comp_size) {
            free(best.compressed); best.compressed = c; best.comp_size = cs; best.preproc_type = 0;
        } else { free(c); }
    }
    
    if (is_code && arch_type == 1 && size >= 16) {
        uint8_t *tmp = malloc(size);
        memcpy(tmp, data, size);
        arm64_branch_normalize(tmp, size);
        uint8_t *planes = arm64_planes_encode(tmp, size);
        free(tmp);
        
        if (planes) {
            uint64_t n_instr = size / 4;
            if (n_instr > 1) {
                delta_encode(planes, n_instr);
                delta_encode(planes + n_instr, n_instr);
                delta_encode(planes + 2*n_instr, n_instr);
                delta_encode(planes + 3*n_instr, n_instr);
            }
            size_t cs;
            uint8_t *c = lzma_compress_buf(planes, size, &cs, 0, 0, 0, opt_level);
            free(planes);
            if (c && cs < best.comp_size) {
                free(best.compressed); best.compressed = c; best.comp_size = cs; best.preproc_type = 1;
            } else { free(c); }
        }
    }
    
    if (size >= 4) {
        uint8_t *tmp = malloc(size);
        memcpy(tmp, data, size);
        delta_encode(tmp, size);
        size_t cs;
        uint8_t *c = lzma_compress_buf(tmp, size, &cs, 0, 0, 0, opt_level);
        free(tmp);
        if (c && cs < best.comp_size) {
            free(best.compressed); best.compressed = c; best.comp_size = cs; best.preproc_type = 2;
        } else { free(c); }
    }
    
    return best;
}


#define MAGIC "UCOMP01"
#define MAGIC_LEN 8

static void write_le32(uint8_t *buf, uint32_t v) {
    buf[0] = v & 0xFF; buf[1] = (v>>8)&0xFF; buf[2] = (v>>16)&0xFF; buf[3] = (v>>24)&0xFF;
}
static void write_le64(uint8_t *buf, uint64_t v) {
    for (int i = 0; i < 8; i++) buf[i] = (v >> (i*8)) & 0xFF;
}
static uint32_t read_le32(const uint8_t *buf) {
    return buf[0] | (buf[1]<<8) | (buf[2]<<16) | ((uint32_t)buf[3]<<24);
}
static uint64_t read_le64(const uint8_t *buf) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= ((uint64_t)buf[i]) << (i*8);
    return v;
}

typedef struct {
    uint64_t offset;
    uint64_t size;
    int      is_code;
} Section;

static int parse_elf_sections(const uint8_t *data, uint64_t file_size, 
                               Section **out_sections, int *out_count, int *arch_type) {
    *arch_type = 0;
    if (file_size < sizeof(Elf64_Ehdr)) return 0;
    const Elf64_Ehdr *ehdr = (const Elf64_Ehdr *)data;
    
    if (memcmp(ehdr->e_ident, "\x7f""ELF", 4) != 0) return 0;
    
    if (ehdr->e_machine == EM_AARCH64) {
        *arch_type = 1;
    } else if (ehdr->e_machine == EM_X86_64 || ehdr->e_machine == EM_386) {
        *arch_type = 2;
    } else {
        return 0; 
    }
    
    if (ehdr->e_ident[4] != 2) return 0; 
    
    uint64_t shoff = ehdr->e_shoff;
    uint16_t shnum = ehdr->e_shnum;
    uint16_t shentsize = ehdr->e_shentsize;
    
    if (shoff == 0 || shnum == 0) return 0;
    if (shoff + (uint64_t)shnum * shentsize > file_size) return 0;
    
    Section *secs = malloc(shnum * sizeof(Section));
    int count = 0;
    
    for (int i = 0; i < shnum; i++) {
        const Elf64_Shdr *shdr = (const Elf64_Shdr *)(data + shoff + i * shentsize);
        if (shdr->sh_type != 1) continue;
        if (shdr->sh_size == 0) continue;
        if (shdr->sh_offset + shdr->sh_size > file_size) continue;
        
        secs[count].offset = shdr->sh_offset;
        secs[count].size = shdr->sh_size;
        secs[count].is_code = (shdr->sh_flags & SHF_EXECINSTR) ? 1 : 0;
        count++;
    }
    
    for (int i = 0; i < count - 1; i++) {
        for (int j = i + 1; j < count; j++) {
            if (secs[j].offset < secs[i].offset) {
                Section tmp = secs[i]; secs[i] = secs[j]; secs[j] = tmp;
            }
        }
    }
    *out_sections = secs;
    *out_count = count;
    return 1;
}

void compress_file(const char *in_path, const char *out_path, int opt_level) {
    FILE *fin = fopen(in_path, "rb");
    if (!fin) { perror("fopen входного файла"); return; }
    fseek(fin, 0, SEEK_END);
    uint64_t file_size = ftell(fin);
    fseek(fin, 0, SEEK_SET);
    uint8_t *data = malloc(file_size);
    fread(data, 1, file_size, fin);
    fclose(fin);
    
    printf("[*] Входной файл: %s (%lu байт)\n", in_path, (unsigned long)file_size);
    
    Section *elf_secs = NULL;
    int elf_sec_count = 0;
    int arch_type = 0;
    int is_elf = parse_elf_sections(data, file_size, &elf_secs, &elf_sec_count, &arch_type);
    
    if (is_elf) {
        printf("[*] Обнаружен ELF. Архитектура: %s\n", arch_type == 1 ? "ARM64" : "x86 / x86_64");
    }
    
    typedef struct { uint64_t off; uint64_t sz; int is_code; } Chunk;
    Chunk *chunks = NULL;
    int n_chunks = 0;
    
    if (is_elf && elf_sec_count > 0) {
        chunks = malloc((elf_sec_count * 2 + 2) * sizeof(Chunk));
        uint64_t pos = 0;
        for (int i = 0; i < elf_sec_count; i++) {
            if (elf_secs[i].offset > pos) {
                chunks[n_chunks++] = (Chunk){pos, elf_secs[i].offset - pos, 0};
            }
            chunks[n_chunks++] = (Chunk){elf_secs[i].offset, elf_secs[i].size, elf_secs[i].is_code};
            pos = elf_secs[i].offset + elf_secs[i].size;
        }
        if (pos < file_size) {
            chunks[n_chunks++] = (Chunk){pos, file_size - pos, 0};
        }
    } else {
        chunks = malloc(sizeof(Chunk));
        chunks[0] = (Chunk){0, file_size, 0};
        n_chunks = 1;
    }
    free(elf_secs);
    
    int hw_threads = 1;
#ifdef _OPENMP
    hw_threads = omp_get_max_threads();
#endif

    int chunk_threads = 1;
    if (opt_level >= 3) chunk_threads = hw_threads;
    else if (opt_level == 2) chunk_threads = (hw_threads > 8) ? 8 : hw_threads;
    else if (opt_level == 1) chunk_threads = (hw_threads > 3) ? 3 : hw_threads;
    if (opt_level == 2 && file_size < (1u << 20) && chunk_threads > 4) chunk_threads = 4;
    if (file_size < (1u << 20) && chunk_threads > 2) chunk_threads = 2;
    if (chunk_threads < 1) chunk_threads = 1;

    size_t multi_total = (size_t)-1;
    ChunkResult *results = NULL;
    int run_multi = (opt_level > 0);
    
    if (run_multi) {
        printf("[*] Сжатие мульти-блоком (%d чанков). Используются все ядра CPU...\n", n_chunks);
        
        results = malloc(n_chunks * sizeof(ChunkResult));
        size_t total_payload = 0;
        
        #pragma omp parallel for schedule(dynamic, 1) num_threads(chunk_threads)
        for (int i = 0; i < n_chunks; i++) {
            results[i] = compress_chunk_best(data + chunks[i].off, chunks[i].sz, chunks[i].is_code, arch_type, opt_level);
        }
        
        for (int i = 0; i < n_chunks; i++) total_payload += results[i].comp_size;
        
        size_t multi_overhead = MAGIC_LEN + 8 + 4 + n_chunks * (1 + 4 + 4); 
        multi_total = multi_overhead + total_payload;
        printf("[*] Мульти-блочный метод: %lu байт\n", (unsigned long)multi_total);
    }

    static const int smart_combos[][3] = {
        {3, 0, 2}, {4, 0, 2}, {2, 0, 2}, {3, 1, 2}, {2, 2, 2}, {1, 3, 2}, {0, 4, 2},
        {4, 0, 1}, {3, 1, 1}, {2, 2, 1}, {1, 3, 1}, {0, 4, 1},
        {4, 0, 0}, {3, 1, 0}, {2, 2, 0}, {1, 3, 0}, {0, 4, 0},
        {0, 0, 2}, {0, 1, 2}
    };
    #define NUM_SMART_COMBOS 19
    
    int lcs_arr[] = {3, 0, 1, 2, 4};
    int lps_arr[] = {0, 1, 2};
    int pbs_arr[] = {2, 0, 1};
    int lcs_count = 5, lps_count = 3, pbs_count = 3;

    uint8_t *tmp_norm = NULL;
    uint8_t *tmp_adv = NULL;
    uint8_t *tmp_total_delta = NULL;
    uint8_t *tmp_norm_total_delta = NULL;

    int need_adv_mode = (is_elf && arch_type == 1 && opt_level >= 2);
    int need_total_delta_mode = (opt_level >= 3) || (opt_level >= 2 && !is_elf);
    int need_norm_total_delta_mode = (opt_level >= 3) || (opt_level >= 2 && is_elf && arch_type == 2);

    if (need_total_delta_mode) {
        tmp_total_delta = malloc(file_size);
        if (tmp_total_delta) {
            memcpy(tmp_total_delta, data, file_size);
            delta_encode(tmp_total_delta, file_size);
        }
    }

    if (is_elf && opt_level >= 1) {
        tmp_norm = malloc(file_size);
        if (tmp_norm) {
            memcpy(tmp_norm, data, file_size);
            for (int i = 0; i < n_chunks; i++) {
                if (chunks[i].is_code) {
                    if (arch_type == 1) arm64_branch_normalize(tmp_norm + chunks[i].off, chunks[i].sz);
                    else if (arch_type == 2) x86_branch_normalize(tmp_norm + chunks[i].off, chunks[i].sz);
                }
            }
        }

        if (opt_level >= 2 && tmp_norm) {
            if (need_adv_mode) {
                tmp_adv = malloc(file_size);
                if (tmp_adv) {
                    memcpy(tmp_adv, data, file_size);
                    for (int i = 0; i < n_chunks; i++) {
                        if (chunks[i].is_code) {
                            size_t sz = chunks[i].sz;
                            uint8_t *ptr = tmp_adv + chunks[i].off;
                            arm64_branch_normalize(ptr, sz);
                            uint8_t *planes = arm64_planes_encode(ptr, sz);
                            if (planes) {
                                uint64_t n_instr = sz / 4;
                                if (n_instr > 1) {
                                    delta_encode(planes, n_instr);
                                    delta_encode(planes + n_instr, n_instr);
                                    delta_encode(planes + 2*n_instr, n_instr);
                                    delta_encode(planes + 3*n_instr, n_instr);
                                }
                                memcpy(ptr, planes, sz);
                                free(planes);
                            }
                        }
                    }
                }
            }

            if (need_norm_total_delta_mode) {
                tmp_norm_total_delta = malloc(file_size);
                if (tmp_norm_total_delta) {
                    memcpy(tmp_norm_total_delta, tmp_norm, file_size);
                    delta_encode(tmp_norm_total_delta, file_size);
                }
            }
        }
    }

    typedef struct { uint8_t *buf; uint8_t type; } PreprocMode;
    PreprocMode modes_table[8];
    int num_bf_modes = 0;
    
    modes_table[num_bf_modes++] = (PreprocMode){data, 0};
    if (tmp_norm) modes_table[num_bf_modes++] = (PreprocMode){tmp_norm, 3};
    if (opt_level >= 3) {
        if (tmp_adv)              modes_table[num_bf_modes++] = (PreprocMode){tmp_adv, 4};
        if (tmp_total_delta)      modes_table[num_bf_modes++] = (PreprocMode){tmp_total_delta, 5};
        if (tmp_norm_total_delta) modes_table[num_bf_modes++] = (PreprocMode){tmp_norm_total_delta, 6};
    } else if (opt_level >= 2) {
        if (tmp_adv)                                           modes_table[num_bf_modes++] = (PreprocMode){tmp_adv, 4};
        if (!is_elf && tmp_total_delta)                        modes_table[num_bf_modes++] = (PreprocMode){tmp_total_delta, 5};
        if (is_elf && arch_type == 2 && tmp_norm_total_delta)  modes_table[num_bf_modes++] = (PreprocMode){tmp_norm_total_delta, 6};
    }
    
    int num_combos;
    if (opt_level >= 3) num_combos = lcs_count * lps_count * pbs_count;
    else if (opt_level >= 2) num_combos = NUM_SMART_COMBOS;
    else num_combos = 1;
    
    int total_passes = num_combos * num_bf_modes;
    int selected_passes[64];
    int selected_count = 0;

    if (0 && opt_level == 2 && total_passes > 6) {
        int top_k = (file_size >= (2u << 20)) ? 2 : 1;
        if (top_k > total_passes) top_k = total_passes;

        size_t sample_size = file_size;
        if (sample_size > 262144) sample_size = 262144;

        size_t best_scores[8];
        int best_indices[8];
        for (int i = 0; i < 8; i++) {
            best_scores[i] = (size_t)-1;
            best_indices[i] = -1;
        }

        for (int p = 0; p < total_passes; p++) {
            int combo_idx = p / num_bf_modes;
            int mode_idx = p % num_bf_modes;

            int lc = smart_combos[combo_idx][0];
            int lp = smart_combos[combo_idx][1];
            int pb = smart_combos[combo_idx][2];

            size_t scomp = 0;
            uint8_t *tmp = lzma_compress_buf(modes_table[mode_idx].buf, sample_size, &scomp, lc, lp, pb, 1);
            if (!tmp) continue;
            free(tmp);

            for (int k = 0; k < top_k; k++) {
                if (scomp < best_scores[k]) {
                    for (int z = top_k - 1; z > k; z--) {
                        best_scores[z] = best_scores[z - 1];
                        best_indices[z] = best_indices[z - 1];
                    }
                    best_scores[k] = scomp;
                    best_indices[k] = p;
                    break;
                }
            }
        }

        selected_passes[selected_count++] = 0;
        for (int m = 1; m < num_bf_modes; m++) {
            int idx = m;
            if (selected_count < (int)(sizeof(selected_passes) / sizeof(selected_passes[0]))) {
                selected_passes[selected_count++] = idx;
            }
        }
        if (NUM_SMART_COMBOS > 1) {
            for (int m = 0; m < num_bf_modes; m++) {
                int idx = num_bf_modes + m;
                int exists = 0;
                for (int j = 0; j < selected_count; j++) {
                    if (selected_passes[j] == idx) {
                        exists = 1;
                        break;
                    }
                }
                if (!exists && selected_count < (int)(sizeof(selected_passes) / sizeof(selected_passes[0]))) {
                    selected_passes[selected_count++] = idx;
                }
            }
        }
        if (is_elf && arch_type == 2) {
            int extra_combos[] = {3, 7};
            int extra_count = (int)(sizeof(extra_combos) / sizeof(extra_combos[0]));
            for (int m = 0; m < num_bf_modes; m++) {
                if (modes_table[m].type != 6) continue;
                for (int ec = 0; ec < extra_count; ec++) {
                    if (extra_combos[ec] >= NUM_SMART_COMBOS) continue;
                    int idx = extra_combos[ec] * num_bf_modes + m;
                    int exists = 0;
                    for (int j = 0; j < selected_count; j++) {
                        if (selected_passes[j] == idx) {
                            exists = 1;
                            break;
                        }
                    }
                    if (!exists && selected_count < (int)(sizeof(selected_passes) / sizeof(selected_passes[0]))) {
                        selected_passes[selected_count++] = idx;
                    }
                }
            }
        }

        for (int i = 0; i < top_k; i++) {
            int idx = best_indices[i];
            if (idx < 0) continue;
            int exists = 0;
            for (int j = 0; j < selected_count; j++) {
                if (selected_passes[j] == idx) {
                    exists = 1;
                    break;
                }
            }
            if (!exists && selected_count < (int)(sizeof(selected_passes) / sizeof(selected_passes[0]))) {
                selected_passes[selected_count++] = idx;
            }
        }

        total_passes = selected_count;
        printf("[*] Mode2 shortlist: %d кандидатов из %d (sample=%lu байт)\n", selected_count, num_combos * num_bf_modes, (unsigned long)sample_size);
    }
    
    int bf_threads = 1;
    #ifdef _OPENMP
    bf_threads = hw_threads;
    if (opt_level == 2) bf_threads = (hw_threads > 8) ? 8 : hw_threads;
    else if (opt_level <= 1 && bf_threads > 6) bf_threads = 6;
    if (total_passes < bf_threads) bf_threads = total_passes;
    if (bf_threads < 1) bf_threads = 1;
    printf("[*] Запуск ОПТИМИЗАТОРА (Уровень: %d | Потоков: %d | Комбинаций: %d)\n", opt_level, bf_threads, total_passes);
    #else
    printf("[*] Запуск ОПТИМИЗАТОРА (Уровень: %d | Потоков: 1 | Комбинаций: %d)\n", opt_level, total_passes);
    #endif

    size_t best_single_size = (size_t)-1;
    uint8_t *best_single_comp = NULL;
    uint8_t best_single_type = 0;
    int current_pass = 0;
    int report_step = (total_passes >= 20) ? (total_passes / 20) : 1;

    #pragma omp parallel for schedule(dynamic, 1) num_threads(bf_threads)
    for (int p = 0; p < total_passes; p++) {
        int pass_idx = (opt_level == 2 && selected_count > 0) ? selected_passes[p] : p;
        int combo_idx = pass_idx / num_bf_modes;
        int mode_idx = pass_idx % num_bf_modes;
        
        int lc, lp, pb;
        if (opt_level >= 3) {
            int lc_idx = combo_idx / (pbs_count * lps_count);
            int lp_idx = (combo_idx / pbs_count) % lps_count;
            int pb_idx = combo_idx % pbs_count;
            lc = lcs_arr[lc_idx];
            lp = lps_arr[lp_idx];
            pb = pbs_arr[pb_idx];
        } else if (opt_level >= 2) {
            lc = smart_combos[combo_idx][0];
            lp = smart_combos[combo_idx][1];
            pb = smart_combos[combo_idx][2];
        } else {
            lc = 3; lp = 0; pb = 2;
        }
        
        uint8_t *in_buf = modes_table[mode_idx].buf;
        uint8_t preproc_type = modes_table[mode_idx].type;
        
        size_t csize;
        uint8_t *comp = lzma_compress_buf(in_buf, file_size, &csize, lc, lp, pb, opt_level);
        
        #pragma omp critical
        {
            if (comp && csize < best_single_size) {
                free(best_single_comp);
                best_single_comp = comp;
                best_single_size = csize;
                best_single_type = preproc_type;
            } else {
                free(comp);
            }
            current_pass++;
            if (total_passes > 2 && (current_pass == total_passes || (current_pass % report_step) == 0)) {
                printf("\r    Анализ вариантов: %d / %d ...", current_pass, total_passes);
                fflush(stdout);
            }
        }
    }
    if (total_passes > 2) printf("\r    Анализ вариантов: %d / %d ... Готово!    \n", total_passes, total_passes);

    if (tmp_norm) free(tmp_norm);
    if (tmp_adv) free(tmp_adv);
    if (tmp_total_delta) free(tmp_total_delta);
    if (tmp_norm_total_delta) free(tmp_norm_total_delta);
    
    size_t single_total = MAGIC_LEN + 8 + 4 + 1 + 4 + 4 + best_single_size; 
    printf("[*] Лучший результат единым блоком: %lu байт (препроцессинг: %d)\n", (unsigned long)single_total, best_single_type);
    
    FILE *fout = fopen(out_path, "wb");
    if (!fout) { perror("fopen выходного файла"); goto cleanup; }
    
    if (best_single_comp && single_total < multi_total) {
        printf("[*] Выбран метод единого блока (максимальное сжатие)\n");
        uint8_t hdr[MAGIC_LEN + 8 + 4];
        memcpy(hdr, MAGIC, MAGIC_LEN);
        write_le64(hdr + MAGIC_LEN, file_size);
        write_le32(hdr + MAGIC_LEN + 8, 1);
        fwrite(hdr, 1, sizeof(hdr), fout);
        
        uint8_t chunk_hdr[9];
        chunk_hdr[0] = best_single_type; 
        write_le32(chunk_hdr + 1, (uint32_t)file_size);
        write_le32(chunk_hdr + 5, (uint32_t)best_single_size);
        fwrite(chunk_hdr, 1, 9, fout);
        fwrite(best_single_comp, 1, best_single_size, fout);
    } else {
        printf("[*] Выбран мульти-блочный метод\n");
        uint8_t hdr[MAGIC_LEN + 8 + 4];
        memcpy(hdr, MAGIC, MAGIC_LEN);
        write_le64(hdr + MAGIC_LEN, file_size);
        write_le32(hdr + MAGIC_LEN + 8, (uint32_t)n_chunks);
        fwrite(hdr, 1, sizeof(hdr), fout);
        
        for (int i = 0; i < n_chunks; i++) {
            uint8_t chunk_hdr[9];
            chunk_hdr[0] = results[i].preproc_type;
            write_le32(chunk_hdr + 1, (uint32_t)results[i].orig_size);
            write_le32(chunk_hdr + 5, (uint32_t)results[i].comp_size);
            fwrite(chunk_hdr, 1, 9, fout);
            fwrite(results[i].compressed, 1, results[i].comp_size, fout);
        }
    }
    
    fclose(fout);
    
    {
        FILE *ff = fopen(out_path, "rb");
        fseek(ff, 0, SEEK_END);
        long out_size = ftell(ff);
        fclose(ff);
        printf("\n[+] РЕЗУЛЬТАТ: %lu -> %ld байт (%.2f%%)\n", 
               (unsigned long)file_size, out_size, 100.0 * out_size / file_size);
    }
    
cleanup:
    if (results) {
        for (int i = 0; i < n_chunks; i++) free(results[i].compressed);
        free(results);
    }
    free(chunks);
    if (best_single_comp) free(best_single_comp);
    free(data);
}

void decompress_file(const char *in_path, const char *out_path) {
    FILE *fin = fopen(in_path, "rb");
    if (!fin) { perror("fopen входного файла"); return; }
    fseek(fin, 0, SEEK_END);
    long file_size = ftell(fin);
    fseek(fin, 0, SEEK_SET);
    uint8_t *data = malloc(file_size);
    fread(data, 1, file_size, fin);
    fclose(fin);
    
    if (file_size < MAGIC_LEN + 12 || memcmp(data, MAGIC, MAGIC_LEN) != 0) {
        fprintf(stderr, "[!] Неверный архив (магическое число не совпадает)\n");
        free(data);
        return;
    }
    
    uint64_t orig_size = read_le64(data + MAGIC_LEN);
    uint32_t n_chunks = read_le32(data + MAGIC_LEN + 8);
    
    printf("[*] Распаковка: %u блоков, исходный размер %lu байт\n", n_chunks, (unsigned long)orig_size);
    
    uint8_t *output = malloc(orig_size);
    if (!output) { fprintf(stderr, "[!] Ошибка malloc (не хватает памяти)\n"); free(data); return; }
    
    size_t pos = MAGIC_LEN + 8 + 4;
    size_t out_pos = 0;
    
    for (uint32_t i = 0; i < n_chunks; i++) {
        uint8_t preproc_type = data[pos];
        uint32_t chunk_orig = read_le32(data + pos + 1);
        uint32_t chunk_comp = read_le32(data + pos + 5);
        pos += 9;
        
        uint8_t *decompressed = lzma_decompress_buf(data + pos, chunk_comp, chunk_orig);
        pos += chunk_comp;
        
        if (!decompressed) {
            fprintf(stderr, "[!] Ошибка распаковки блока %u\n", i);
            free(output); free(data);
            return;
        }
        
        if (preproc_type == 1) { 
            uint64_t n_instr = chunk_orig / 4;
            if (n_instr > 1) {
                delta_decode(decompressed, n_instr);
                delta_decode(decompressed + n_instr, n_instr);
                delta_decode(decompressed + 2*n_instr, n_instr);
                delta_decode(decompressed + 3*n_instr, n_instr);
            }
            uint8_t *unplaned = arm64_planes_decode(decompressed, chunk_orig);
            free(decompressed);
            decompressed = unplaned;
            arm64_branch_denormalize(decompressed, chunk_orig);
        } 
        else if (preproc_type == 2) {
            delta_decode(decompressed, chunk_orig);
        } 
        else if (preproc_type == 3) {
            Section *secs = NULL;
            int sec_count = 0;
            int arch = 0;
            if (parse_elf_sections(decompressed, chunk_orig, &secs, &sec_count, &arch)) {
                for (int s = 0; s < sec_count; s++) {
                    if (secs[s].is_code) {
                        if (arch == 1) arm64_branch_denormalize(decompressed + secs[s].offset, secs[s].size);
                        else if (arch == 2) x86_branch_denormalize(decompressed + secs[s].offset, secs[s].size);
                    }
                }
                free(secs);
            }
        }
        else if (preproc_type == 4) { 
            Section *secs = NULL;
            int sec_count = 0;
            int arch = 0;
            if (parse_elf_sections(decompressed, chunk_orig, &secs, &sec_count, &arch)) {
                for (int s = 0; s < sec_count; s++) {
                    if (secs[s].is_code) {
                        if (arch == 1) {
                            size_t sz = secs[s].size;
                            uint8_t *ptr = decompressed + secs[s].offset;
                            uint64_t n_instr = sz / 4;
                            if (n_instr > 1) {
                                delta_decode(ptr, n_instr);
                                delta_decode(ptr + n_instr, n_instr);
                                delta_decode(ptr + 2*n_instr, n_instr);
                                delta_decode(ptr + 3*n_instr, n_instr);
                            }
                            uint8_t *unplaned = arm64_planes_decode(ptr, sz);
                            if (unplaned) {
                                memcpy(ptr, unplaned, sz);
                                free(unplaned);
                            }
                            arm64_branch_denormalize(ptr, sz);
                        } else if (arch == 2) {
                            x86_branch_denormalize(decompressed + secs[s].offset, secs[s].size);
                        }
                    }
                }
                free(secs);
            }
        }
        else if (preproc_type == 5) {
            delta_decode(decompressed, chunk_orig);
        }
        else if (preproc_type == 6) {
            delta_decode(decompressed, chunk_orig);
            Section *secs = NULL;
            int sec_count = 0;
            int arch = 0;
            if (parse_elf_sections(decompressed, chunk_orig, &secs, &sec_count, &arch)) {
                for (int s = 0; s < sec_count; s++) {
                    if (secs[s].is_code) {
                        if (arch == 1) arm64_branch_denormalize(decompressed + secs[s].offset, secs[s].size);
                        else if (arch == 2) x86_branch_denormalize(decompressed + secs[s].offset, secs[s].size);
                    }
                }
                free(secs);
            }
        }
        
        memcpy(output + out_pos, decompressed, chunk_orig);
        out_pos += chunk_orig;
        free(decompressed);
    }
    
    FILE *fout = fopen(out_path, "wb");
    fwrite(output, 1, orig_size, fout);
    fclose(fout);
    
    printf("[+] Успешно распаковано: %lu байт\n", (unsigned long)orig_size);
    
    free(output);
    free(data);
}


void decompress_all(const char *manifest_path) {
    FILE *f = fopen(manifest_path, "r");
    if (!f) {
        fprintf(stderr, "[LGZ] Не удалось открыть манифест: %s\n", manifest_path);
        perror("fopen");
        return;
    }

    char line[1024];
    int ok_count = 0, fail_count = 0;

    while (fgets(line, sizeof(line), f)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        char *cr = strchr(line, '\r');
        if (cr) *cr = '\0';

        if (line[0] == '#' || line[0] == '\0') continue;

        char *space = strchr(line, ' ');
        if (!space) {
            fprintf(stderr, "[LGZ] Неверный формат строки: %s\n", line);
            continue;
        }
        *space = '\0';

        unsigned int perms = (unsigned int)strtoul(line, NULL, 8);
        char *path = space + 1;

        struct stat st;
        if (stat(path, &st) != 0) {
            fprintf(stderr, "[LGZ] Файл не найден: %s\n", path);
            fail_count++;
            continue;
        }

        char tmp_path[1024];
        snprintf(tmp_path, sizeof(tmp_path), "%s.lgz_tmp", path);

        printf("[LGZ] Распаковка: %s\n", path);
        decompress_file(path, tmp_path);

        if (stat(tmp_path, &st) != 0) {
            fprintf(stderr, "[LGZ] Ошибка при распаковке: %s\n", path);
            fail_count++;
            continue;
        }

        if (rename(tmp_path, path) != 0) {
            perror("rename");
            fprintf(stderr, "[LGZ] Ошибка при замене оригинального файла: %s\n", path);
            unlink(tmp_path);
            fail_count++;
            continue;
        }

        chmod(path, (mode_t)perms);
        ok_count++;
    }

    fclose(f);
    printf("[LGZ] Завершено: %d успешно, %d с ошибками\n", ok_count, fail_count);
}


int main(int argc, char *argv[]) {
#ifdef _OPENMP
    omp_set_dynamic(0);
#endif

    if (argc < 2) {
        fprintf(stderr, "Использование:\n");
        fprintf(stderr, "  %s compress <вход> <выход> [уровень 0-3]\n", argv[0]);
        fprintf(stderr, "    Уровни: 0=Быстрый, 1=Баланс, 2=Глубокий(90, по умолч.), 3=Экстремальный(225+)\n");
        fprintf(stderr, "  %s decompress <вход> <выход>\n", argv[0]);
        fprintf(stderr, "  %s decompress_all <манифест>\n", argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "compress") == 0) {
        if (argc < 4 || argc > 5) {
            fprintf(stderr, "Использование: %s compress <входной_файл> <выходной_файл> [уровень_оптимизации 0-3]\n", argv[0]);
            return 1;
        }
        int opt_level = 2;
        if (argc == 5) {
            opt_level = atoi(argv[4]);
            if (opt_level < 0) opt_level = 0;
            if (opt_level > 3) opt_level = 3;
        }
        compress_file(argv[2], argv[3], opt_level);
    } else if (strcmp(argv[1], "decompress") == 0) {
        if (argc != 4) {
            fprintf(stderr, "Использование: %s decompress <входной_файл> <выходной_файл>\n", argv[0]);
            return 1;
        }
        decompress_file(argv[2], argv[3]);
    } else if (strcmp(argv[1], "decompress_all") == 0) {
        if (argc != 3) {
            fprintf(stderr, "Использование: %s decompress_all <путь_к_манифесту>\n", argv[0]);
            return 1;
        }
        decompress_all(argv[2]);
    } else {
        fprintf(stderr, "Неизвестная команда: %s\n", argv[1]);
        return 1;
    }
    return 0;
}