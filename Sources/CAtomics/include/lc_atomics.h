// Minimal C11 atomics shim so Swift code can use acquire/release semantics on
// real-time threads (audio render callback, capture callbacks) without locks.
// Swift's own `Synchronization.Atomic` needs macOS 15; this keeps macOS 13 support.
#ifndef LC_ATOMICS_H
#define LC_ATOMICS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { _Alignas(8) volatile uint64_t value; } lc_atomic_u64;
typedef struct { _Alignas(4) volatile uint32_t value; } lc_atomic_u32;

void     lc_atomic_u64_init(lc_atomic_u64 *a, uint64_t v);
uint64_t lc_atomic_u64_load_acquire(const lc_atomic_u64 *a);
uint64_t lc_atomic_u64_load_relaxed(const lc_atomic_u64 *a);
void     lc_atomic_u64_store_release(lc_atomic_u64 *a, uint64_t v);
uint64_t lc_atomic_u64_fetch_add(lc_atomic_u64 *a, uint64_t v);

void     lc_atomic_u32_init(lc_atomic_u32 *a, uint32_t v);
uint32_t lc_atomic_u32_load(const lc_atomic_u32 *a);
void     lc_atomic_u32_store(lc_atomic_u32 *a, uint32_t v);
uint32_t lc_atomic_u32_exchange(lc_atomic_u32 *a, uint32_t v);
bool     lc_atomic_u32_cas(lc_atomic_u32 *a, uint32_t expected, uint32_t desired);

#ifdef __cplusplus
}
#endif
#endif
