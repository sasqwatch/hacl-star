/* This file auto-generated by KreMLin! */
#ifndef __Hacl_Symmetric_HSalsa20_H
#define __Hacl_Symmetric_HSalsa20_H



#include "kremlib.h"
#include "testlib.h"

typedef uint32_t Hacl_Symmetric_HSalsa20_h32;

typedef uint32_t Hacl_Symmetric_HSalsa20_u32;

typedef uint8_t *Hacl_Symmetric_HSalsa20_uint8_p;

uint32_t Hacl_Symmetric_HSalsa20_rotate(uint32_t a, uint32_t s);

uint32_t Hacl_Symmetric_HSalsa20_load32_le(uint8_t *k);

void Hacl_Symmetric_HSalsa20_store32_le(uint8_t *k, uint32_t x);

void
Hacl_Symmetric_HSalsa20_crypto_core_hsalsa20(uint8_t *output, uint8_t *input, uint8_t *key);
#endif
