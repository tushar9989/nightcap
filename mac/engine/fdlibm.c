// fdlibm's __ieee754_log and __ieee754_log10, which V8 uses for Math.log10.
// Subtitle sync rounds 10*log10(energy) to float32 and must match the
// JavaScript engine exactly; macOS's log10 differs in the last bit for about
// 3% of inputs. Matched V8 on 500,000 inputs when compiled with clang's default
// floating-point contraction (fused multiply-adds within an expression, as in
// V8's own build); -ffp-contract=off gives 430 mismatches. Keep the default.
#include <stdint.h>
#include <string.h>
#include "fdlibm.h"

#define EXTRACT_WORDS(hi, lo, d) do { uint64_t bits_; memcpy(&bits_, &(d), 8); (hi) = (int32_t)(bits_ >> 32); (lo) = (uint32_t)bits_; } while (0)
#define GET_HIGH_WORD(hi, d) do { uint64_t bits_; memcpy(&bits_, &(d), 8); (hi) = (int32_t)(bits_ >> 32); } while (0)
#define SET_HIGH_WORD(d, v) do { uint64_t bits_; memcpy(&bits_, &(d), 8); bits_ = (bits_ & 0xffffffffULL) | ((uint64_t)(uint32_t)(v) << 32); memcpy(&(d), &bits_, 8); } while (0)
#define SET_LOW_WORD(d, v) do { uint64_t bits_; memcpy(&bits_, &(d), 8); bits_ = (bits_ & 0xffffffff00000000ULL) | (uint32_t)(v); memcpy(&(d), &bits_, 8); } while (0)

static double fd_log(double x) {
  static const double
      ln2_hi = 6.93147180369123816490e-01,
      ln2_lo = 1.90821492927058770002e-10,
      two54 = 1.80143985094819840000e+16,
      Lg1 = 6.666666666666735130e-01,
      Lg2 = 3.999999999940941908e-01,
      Lg3 = 2.857142874366239149e-01,
      Lg4 = 2.222219843214978396e-01,
      Lg5 = 1.818357216161805012e-01,
      Lg6 = 1.531383769920937332e-01,
      Lg7 = 1.479819860511658591e-01;
  static const double zero = 0.0;
  static volatile double vzero = 0.0;
  double hfsq, f, s, z, R, w, t1, t2, dk;
  int32_t k, hx, i, j;
  uint32_t lx;
  EXTRACT_WORDS(hx, lx, x);
  k = 0;
  if (hx < 0x00100000) {
    if (((hx & 0x7fffffff) | lx) == 0) return -two54 / vzero;
    if (hx < 0) return (x - x) / zero;
    k -= 54;
    x *= two54;
    GET_HIGH_WORD(hx, x);
  }
  if (hx >= 0x7ff00000) return x + x;
  k += (hx >> 20) - 1023;
  hx &= 0x000fffff;
  i = (hx + 0x95f64) & 0x100000;
  SET_HIGH_WORD(x, hx | (i ^ 0x3ff00000));
  k += (i >> 20);
  f = x - 1.0;
  if ((0x000fffff & (2 + hx)) < 3) {
    if (f == zero) {
      if (k == 0) {
        return zero;
      } else {
        dk = (double)k;
        return dk * ln2_hi + dk * ln2_lo;
      }
    }
    R = f * f * (0.5 - 0.33333333333333333 * f);
    if (k == 0) {
      return f - R;
    } else {
      dk = (double)k;
      return dk * ln2_hi - ((R - dk * ln2_lo) - f);
    }
  }
  s = f / (2.0 + f);
  dk = (double)k;
  z = s * s;
  i = hx - 0x6147a;
  w = z * z;
  j = 0x6b851 - hx;
  t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
  t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
  i |= j;
  R = t2 + t1;
  if (i > 0) {
    hfsq = 0.5 * f * f;
    if (k == 0)
      return f - (hfsq - s * (hfsq + R));
    else
      return dk * ln2_hi - ((hfsq - (s * (hfsq + R) + dk * ln2_lo)) - f);
  } else {
    if (k == 0)
      return f - s * (f - R);
    else
      return dk * ln2_hi - ((s * (f - R) - dk * ln2_lo) - f);
  }
}

double nc_fdlibm_log10(double x) {
  static const double
      two54 = 1.80143985094819840000e+16,
      ivln10 = 4.34294481903251816668e-01,
      log10_2hi = 3.01029995663611771306e-01,
      log10_2lo = 3.69423907715893078616e-13;
  static const double zero = 0.0;
  static volatile double vzero = 0.0;
  double y, z;
  int32_t i, k, hx;
  uint32_t lx;
  EXTRACT_WORDS(hx, lx, x);
  k = 0;
  if (hx < 0x00100000) {
    if (((hx & 0x7fffffff) | lx) == 0) return -two54 / vzero;
    if (hx < 0) return (x - x) / zero;
    k -= 54;
    x *= two54;
    GET_HIGH_WORD(hx, x);
    EXTRACT_WORDS(hx, lx, x);
  }
  if (hx >= 0x7ff00000) return x + x;
  if (hx == 0x3ff00000 && lx == 0) return zero;
  k += (hx >> 20) - 1023;
  i = ((uint32_t)k & 0x80000000) >> 31;
  hx = (hx & 0x000fffff) | ((0x3ff - i) << 20);
  y = k + i;
  SET_HIGH_WORD(x, hx);
  SET_LOW_WORD(x, lx);
  z = y * log10_2lo + ivln10 * fd_log(x);
  return z + y * log10_2hi;
}
