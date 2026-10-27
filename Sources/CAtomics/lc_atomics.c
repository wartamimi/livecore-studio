#include "lc_atomics.h"
#include <stdatomic.h>

#define A64(p) ((_Atomic uint64_t *)(void *)&(p)->value)
#define A32(p) ((_Atomic uint32_t *)(void *)&(p)->value)

void lc_atomic_u64_init(lc_atomic_u64 *a, uint64_t v) { atomic_init(A64(a), v); }
uint64_t lc_atomic_u64_load_acquire(const lc_atomic_u64 *a) {
    return atomic_load_explicit(A64((lc_atomic_u64 *)a), memory_order_acquire);
}
uint64_t lc_atomic_u64_load_relaxed(const lc_atomic_u64 *a) {
    return atomic_load_explicit(A64((lc_atomic_u64 *)a), memory_order_relaxed);
}
void lc_atomic_u64_store_release(lc_atomic_u64 *a, uint64_t v) {
    atomic_store_explicit(A64(a), v, memory_order_release);
}
uint64_t lc_atomic_u64_fetch_add(lc_atomic_u64 *a, uint64_t v) {
    return atomic_fetch_add_explicit(A64(a), v, memory_order_acq_rel);
}

void lc_atomic_u32_init(lc_atomic_u32 *a, uint32_t v) { atomic_init(A32(a), v); }
uint32_t lc_atomic_u32_load(const lc_atomic_u32 *a) {
    return atomic_load_explicit(A32((lc_atomic_u32 *)a), memory_order_acquire);
}
void lc_atomic_u32_store(lc_atomic_u32 *a, uint32_t v) {
    atomic_store_explicit(A32(a), v, memory_order_release);
}
uint32_t lc_atomic_u32_exchange(lc_atomic_u32 *a, uint32_t v) {
    return atomic_exchange_explicit(A32(a), v, memory_order_acq_rel);
}
bool lc_atomic_u32_cas(lc_atomic_u32 *a, uint32_t expected, uint32_t desired) {
    return atomic_compare_exchange_strong_explicit(A32(a), &expected, desired,
                                                   memory_order_acq_rel, memory_order_acquire);
}
