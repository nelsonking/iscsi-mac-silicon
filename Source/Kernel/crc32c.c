/* crc32c.c -- compute CRC-32C using the Intel crc32 instruction
 * Copyright (C) 2013 Mark Adler
 * Original Version 1.1  1 Aug 2013  Mark Adler
 * Current  Version 1.2  2 Feb 2015
 */

/*
 This software is provided 'as-is', without any express or implied
 warranty.  In no event will the author be held liable for any damages
 arising from the use of this software.
 
 Permission is granted to anyone to use this software for any purpose,
 including commercial applications, and to alter it and redistribute it
 freely, subject to the following restrictions:
 
 1. The origin of this software must not be misrepresented; you must not
 claim that you wrote the original software. If you use this software
 in a product, an acknowledgment in the product documentation would be
 appreciated but is not required.
 2. Altered source versions must be plainly marked as such, and must not be
 misrepresented as being the original software.
 3. This notice may not be removed or altered from any source distribution.
 
 Mark Adler
 madler@alumni.caltech.edu
 */

/* Use hardware CRC instruction on Intel SSE 4.2 processors.  This computes a
 CRC-32C, *not* the CRC-32 used by Ethernet and zip, gzip, etc.  A software
 version is provided as a fall-back, as well as for speed comparisons. */

/* Version history:
 1.0  10 Feb 2013  First version
 1.1   1 Aug 2013  Correct comments on why three crc instructions in parallel
 1.2  20 Dec 2014  Modified by Nareg Sinenian to include hardware CRC32C only
 1.3   4 Oct 2015  Modified by Nareg Sinenian to cast 64-bit vars to 32 bits.
 */

#include "crc32c.h"

/* CRC-32C (iSCSI) polynomial in reversed bit order. */
#define POLY 0x82f63b78

/* Multiply a matrix times a vector over the Galois field of two elements,
 GF(2).  Each element is a bit in an unsigned integer.  mat must have at
 least as many entries as the power of two for most significant one bit in
 vec. */
#if defined(__x86_64__) || defined(__i386__)
/* ===== x86 / x86_64 hardware-accelerated CRC32C (SSE 4.2 crc32 insn) ===== */

static inline uint32_t gf2_matrix_times(uint32_t *mat, uint32_t vec)
{
    uint32_t sum;
    
    sum = 0;
    while (vec) {
        if (vec & 1)
            sum ^= *mat;
        vec >>= 1;
        mat++;
    }
    return sum;
}

/* Multiply a matrix by itself over GF(2).  Both mat and square must have 32
 rows. */
static inline void gf2_matrix_square(uint32_t *square, uint32_t *mat)
{
    int n;
    
    for (n = 0; n < 32; n++)
        square[n] = gf2_matrix_times(mat, mat[n]);
}

/* Construct an operator to apply len zeros to a crc.  len must be a power of
 two.  If len is not a power of two, then the result is the same as for the
 largest power of two less than len.  The result for len == 0 is the same as
 for len == 1.  A version of this routine could be easily written for any
 len, but that is not needed for this application. */
static void crc32c_zeros_op(uint32_t *even, size_t len)
{
    int n;
    uint32_t row;
    uint32_t odd[32];       /* odd-power-of-two zeros operator */
    
    /* put operator for one zero bit in odd */
    odd[0] = POLY;              /* CRC-32C polynomial */
    row = 1;
    for (n = 1; n < 32; n++) {
        odd[n] = row;
        row <<= 1;
    }
    
    /* put operator for two zero bits in even */
    gf2_matrix_square(even, odd);
    
    /* put operator for four zero bits in odd */
    gf2_matrix_square(odd, even);
    
    /* first square will put the operator for one zero byte (eight zero bits),
     in even -- next square puts operator for two zero bytes in odd, and so
     on, until len has been rotated down to zero */
    do {
        gf2_matrix_square(even, odd);
        len >>= 1;
        if (len == 0)
            return;
        gf2_matrix_square(odd, even);
        len >>= 1;
    } while (len);
    
    /* answer ended up in odd -- copy to even */
    for (n = 0; n < 32; n++)
        even[n] = odd[n];
}

/* Take a length and build four lookup tables for applying the zeros operator
 for that length, byte-by-byte on the operand. */
static void crc32c_zeros(uint32_t zeros[][256], size_t len)
{
    uint32_t n;
    uint32_t op[32];
    
    crc32c_zeros_op(op, len);
    for (n = 0; n < 256; n++) {
        zeros[0][n] = gf2_matrix_times(op, n);
        zeros[1][n] = gf2_matrix_times(op, n << 8);
        zeros[2][n] = gf2_matrix_times(op, n << 16);
        zeros[3][n] = gf2_matrix_times(op, n << 24);
    }
}

/* Apply the zeros operator table to crc. */
static inline uint32_t crc32c_shift(uint32_t zeros[][256], uint32_t crc)
{
    return zeros[0][crc & 0xff] ^ zeros[1][(crc >> 8) & 0xff] ^
    zeros[2][(crc >> 16) & 0xff] ^ zeros[3][crc >> 24];
}

/* Block sizes for three-way parallel crc computation.  LONG and SHORT must
 both be powers of two.  The associated string constants must be set
 accordingly, for use in constructing the assembler instructions. */
#define LONG 8192
#define LONGx1 "8192"
#define LONGx2 "16384"
#define SHORT 256
#define SHORTx1 "256"
#define SHORTx2 "512"

/* Tables for hardware crc that shift a crc by LONG and SHORT zeros. */
static uint32_t crc32c_long[4][256];
static uint32_t crc32c_short[4][256];

/* Initialize tables for shifting crcs. */
void crc32c_init()
{
    crc32c_zeros(crc32c_long, LONG);
    crc32c_zeros(crc32c_short, SHORT);
}

/* Compute CRC-32C using the Intel hardware instruction. */
uint32_t crc32c(uint32_t crc,const void * buf,size_t len)
{
    // NS modification - return initial value if buffer empty
    if(!len || !buf)
        return crc;
    
    const unsigned char *next = (const unsigned char *)buf;
    const unsigned char *end;
    uint64_t crc0, crc1, crc2;      /* need to be 64 bits for crc32q */
    
    /* pre-process the crc */
    crc0 = crc ^ 0xffffffff;
    
    /* compute the crc for up to seven leading bytes to bring the data pointer
     to an eight-byte boundary */
    while (len && ((uintptr_t)next & 7) != 0) {
        __asm__("crc32b\t" "(%1), %0"
                : "=r"(crc0)
                : "r"(next), "0"(crc0));
        next++;
        len--;
    }
    
    /* compute the crc on sets of LONG*3 bytes, executing three independent crc
     instructions, each on LONG bytes -- this is optimized for the Nehalem,
     Westmere, Sandy Bridge, and Ivy Bridge architectures, which have a
     throughput of one crc per cycle, but a latency of three cycles */
    while (len >= LONG*3) {
        crc1 = 0;
        crc2 = 0;
        end = next + LONG;
        do {
            __asm__("crc32q\t" "(%3), %0\n\t"
                    "crc32q\t" LONGx1 "(%3), %1\n\t"
                    "crc32q\t" LONGx2 "(%3), %2"
                    : "=r"(crc0), "=r"(crc1), "=r"(crc2)
                    : "r"(next), "0"(crc0), "1"(crc1), "2"(crc2));
            next += 8;
        } while (next < end);
        crc0 = crc32c_shift(crc32c_long, (uint32_t)crc0) ^ crc1;
        crc0 = crc32c_shift(crc32c_long, (uint32_t)crc0) ^ crc2;
        next += LONG*2;
        len -= LONG*3;
    }
    
    /* do the same thing, but now on SHORT*3 blocks for the remaining data less
     than a LONG*3 block */
    while (len >= SHORT*3) {
        crc1 = 0;
        crc2 = 0;
        end = next + SHORT;
        do {
            __asm__("crc32q\t" "(%3), %0\n\t"
                    "crc32q\t" SHORTx1 "(%3), %1\n\t"
                    "crc32q\t" SHORTx2 "(%3), %2"
                    : "=r"(crc0), "=r"(crc1), "=r"(crc2)
                    : "r"(next), "0"(crc0), "1"(crc1), "2"(crc2));
            next += 8;
        } while (next < end);
        crc0 = crc32c_shift(crc32c_short, (uint32_t)crc0) ^ crc1;
        crc0 = crc32c_shift(crc32c_short, (uint32_t)crc0) ^ crc2;
        next += SHORT*2;
        len -= SHORT*3;
    }
    
    /* compute the crc on the remaining eight-byte units less than a SHORT*3
     block */
    end = next + (len - (len & 7));
    while (next < end) {
        __asm__("crc32q\t" "(%1), %0"
                : "=r"(crc0)
                : "r"(next), "0"(crc0));
        next += 8;
    }
    len &= 7;
    
    /* compute the crc for up to seven trailing bytes */
    while (len) {
        __asm__("crc32b\t" "(%1), %0"
                : "=r"(crc0)
                : "r"(next), "0"(crc0));
        next++;
        len--;
    }
    
    /* return a post-processed crc */
    return (uint32_t)crc0 ^ 0xffffffff;
}

#else
/* ===== portable software CRC32C (arm64 & any non-x86 target) =====
 * Slice-by-8 table implementation. Produces bit-for-bit identical results to
 * the Intel crc32 instruction path above: reflected CRC-32C (Castagnoli),
 * poly 0x82F63B78, with pre/post inversion by 0xFFFFFFFF. Verified against the
 * standard check vector crc32c("123456789") == 0xE3069283. */

static uint32_t crc32c_table[8][256];
static int crc32c_ready = 0;

void crc32c_init()
{
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t crc = n;
        for (int k = 0; k < 8; k++)
            crc = (crc & 1) ? (crc >> 1) ^ POLY : (crc >> 1);
        crc32c_table[0][n] = crc;
    }
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t crc = crc32c_table[0][n];
        for (int k = 1; k < 8; k++) {
            crc = (crc >> 8) ^ crc32c_table[0][crc & 0xff];
            crc32c_table[k][n] = crc;
        }
    }
    crc32c_ready = 1;
}

uint32_t crc32c(uint32_t crc,const void * buf,size_t len)
{
    /* NS modification - return initial value if buffer empty */
    if(!len || !buf)
        return crc;

    if(!crc32c_ready)   /* safety net in case crc32c_init() was not called */
        crc32c_init();

    const unsigned char *next = (const unsigned char *)buf;
    crc ^= 0xffffffff;

    /* slice-by-8: consume eight bytes per iteration */
    while (len >= 8) {
        crc ^= (uint32_t)next[0] | ((uint32_t)next[1] << 8) |
               ((uint32_t)next[2] << 16) | ((uint32_t)next[3] << 24);
        uint32_t hi = (uint32_t)next[4] | ((uint32_t)next[5] << 8) |
               ((uint32_t)next[6] << 16) | ((uint32_t)next[7] << 24);
        crc = crc32c_table[7][ crc        & 0xff] ^
              crc32c_table[6][(crc >>  8) & 0xff] ^
              crc32c_table[5][(crc >> 16) & 0xff] ^
              crc32c_table[4][(crc >> 24) & 0xff] ^
              crc32c_table[3][ hi         & 0xff] ^
              crc32c_table[2][(hi  >>  8) & 0xff] ^
              crc32c_table[1][(hi  >> 16) & 0xff] ^
              crc32c_table[0][(hi  >> 24) & 0xff];
        next += 8;
        len  -= 8;
    }

    /* trailing bytes */
    while (len--) {
        crc = crc32c_table[0][(crc ^ *next++) & 0xff] ^ (crc >> 8);
    }

    return crc ^ 0xffffffff;
}

#endif
