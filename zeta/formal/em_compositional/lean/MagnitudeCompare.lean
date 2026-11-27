/-
Correctness of the MPF magnitude comparison on decoded fields.

`zeta_mpf_magnitude` decides `|z| < eps` for `z = re + i*im` given as two MPF
words. In units of `eps^2 / 4^W` (W = mantissa width) a component with
mantissa `m` and exponent `k` steps below eps contributes `m^2 / 4^k`, and the
test is

    m_re^2 / 4^k_re + m_im^2 / 4^k_im < 4^W.

The RTL computes each quotient with a right shift. The model below also
accounts for zero masking, the large-shift cutoff, specials, and the
normalized exponent guard. The exact specification clears the positive
denominators before comparing. The generic theorems start from decoded
values; `decodeMpf` and the `z64_*` corollaries at the end restate them on
packed 87-bit Z64 words. The link to the SystemVerilog text itself is the
`../mag` equivalence check (JasperGold, with an open-source pre-check in
`../mag/mag_equiv.sby`). This file uses Lean core only.
-/

namespace Zeta

/-- One floored term next to an integer term. Flooring `b / d` cannot change
a strict comparison between integers. -/
theorem floor_one_exact (a b d n : Nat) (hd : 0 < d) :
    a + b / d < n ↔ a * d + b < n * d := by
  have h : (a * d + b) / d = a + b / d := by
    rw [Nat.add_comm, Nat.add_mul_div_right _ _ hd, Nat.add_comm]
  rw [← h, Nat.div_lt_iff_lt_mul hd]

/-- Two floored terms, each at least one exponent step below eps: the floored
sum is below the bound. -/
theorem two_floored_below (x y d e n : Nat) (hx : x < n) (hy : y < n)
    (hd : 4 ≤ d) (he : 4 ≤ e) : x / d + y / e < n := by
  have h1 : x / d ≤ x / 4 := Nat.div_le_div_left hd (by decide)
  have h2 : y / e ≤ y / 4 := Nat.div_le_div_left he (by decide)
  omega

/-- The same two terms without flooring (scaled by `d * e` to stay in the
integers) are below the bound as well. -/
theorem two_exact_below (x y d e n : Nat) (hx : x < n) (hy : y < n)
    (hd : 4 ≤ d) (he : 4 ≤ e) : x * e + y * d < n * (d * e) := by
  have h1 : x * e < n * e := Nat.mul_lt_mul_of_pos_right hx (by omega)
  have h2 : y * d < n * d := Nat.mul_lt_mul_of_pos_right hy (by omega)
  have h3 : n * e * 4 ≤ n * (d * e) := by
    calc n * e * 4 ≤ n * e * d := Nat.mul_le_mul_left _ hd
      _ = n * (d * e) := by rw [Nat.mul_assoc, Nat.mul_comm e d]
  have h4 : n * d * 4 ≤ n * (d * e) := by
    calc n * d * 4 ≤ n * d * e := Nat.mul_le_mul_left _ he
      _ = n * (d * e) := by rw [Nat.mul_assoc]
  omega

/-- A positive power of four is at least four. -/
theorem four_le_pow (k : Nat) : 4 ≤ 4 ^ (k + 1) := by
  have h : 0 < 4 ^ k := Nat.pow_pos (by decide)
  rw [Nat.pow_succ]
  omega

/-- The checker's comparison. `x` and `y` are the squared mantissas, `n` the
bound `4^W`, and `k₁`, `k₂` the exponent distances below eps. The floored
test on the left is what the RTL computes; the right side is the exact
inequality multiplied through by `4^k₁ * 4^k₂`. -/
theorem checker_exact (x y n k₁ k₂ : Nat) (hx : x < n) (hy : y < n) :
    x / 4 ^ k₁ + y / 4 ^ k₂ < n ↔ x * 4 ^ k₂ + y * 4 ^ k₁ < n * (4 ^ k₁ * 4 ^ k₂) := by
  cases k₁ with
  | zero =>
    have h := floor_one_exact x y (4 ^ k₂) n (Nat.pow_pos (by decide))
    simpa only [Nat.pow_zero, Nat.div_one, Nat.mul_one, Nat.one_mul] using h
  | succ j₁ =>
    cases k₂ with
    | zero =>
      have h := floor_one_exact y x (4 ^ (j₁ + 1)) n (Nat.pow_pos (by decide))
      simp only [Nat.pow_zero, Nat.div_one, Nat.mul_one]
      rw [Nat.add_comm (x / 4 ^ (j₁ + 1)) y, Nat.add_comm x (y * 4 ^ (j₁ + 1))]
      exact h
    | succ j₂ =>
      exact ⟨fun _ => two_exact_below x y _ _ n hx hy (four_le_pow j₁) (four_le_pow j₂),
             fun _ => two_floored_below x y _ _ n hx hy (four_le_pow j₁) (four_le_pow j₂)⟩

/-- A mantissa below `2^W` has a square below the bound `4^W`. -/
theorem sq_lt_bound (m W : Nat) (hm : m < 2 ^ W) : m * m < 4 ^ W := by
  have h : (4 : Nat) ^ W = 2 ^ W * 2 ^ W := by
    rw [← Nat.mul_pow]
  rw [h]
  exact Nat.mul_lt_mul'' hm hm

/-- The exponent guard. A normalized mantissa (top bit set) whose exponent is
`d ≥ 1` steps above eps is at least eps on its own, so the checker may answer
"not below" without looking at the other component. For a mantissa that is
not normalized this fails, which is the one assumption the checker makes. -/
theorem normalized_reaches (m W d : Nat) (hW : 0 < W) (hm : 2 ^ (W - 1) ≤ m)
    (hd : 1 ≤ d) : 2 ^ W ≤ m * 2 ^ d := by
  have h2 : 2 ≤ 2 ^ d := by
    calc 2 = 2 ^ 1 := by decide
      _ ≤ 2 ^ d := Nat.pow_le_pow_right (by decide) hd
  have hW' : 2 ^ W = 2 ^ (W - 1) * 2 := by
    rw [← Nat.pow_succ, Nat.succ_eq_add_one, Nat.sub_add_cancel hW]
  rw [hW']
  exact Nat.mul_le_mul hm h2

/-- The checker's comparison on mantissas: the statement the RTL implements,
for every width. -/
theorem magnitude_compare_exact (W m₁ m₂ k₁ k₂ : Nat) (h₁ : m₁ < 2 ^ W) (h₂ : m₂ < 2 ^ W) :
    m₁ * m₁ / 4 ^ k₁ + m₂ * m₂ / 4 ^ k₂ < 4 ^ W ↔
      m₁ * m₁ * 4 ^ k₂ + m₂ * m₂ * 4 ^ k₁ < 4 ^ W * (4 ^ k₁ * 4 ^ k₂) :=
  checker_exact _ _ _ k₁ k₂ (sq_lt_bound m₁ W h₁) (sq_lt_bound m₂ W h₂)

/-- Decoded MPF fields relevant to magnitude. `distance` is EPS_EXP minus the
signed MPF exponent. Squaring makes the sign bit immaterial. -/
structure MpfComponent where
  mantissa : Nat
  distance : Int
  isZero : Bool
  isSpecial : Bool

namespace MpfComponent

def effectiveMantissa (c : MpfComponent) : Nat :=
  if c.isZero then 0 else c.mantissa

def Normalized (W : Nat) (c : MpfComponent) : Prop :=
  c.isSpecial = false → c.isZero ≠ true → 2 ^ (W - 1) ≤ c.mantissa

def guard (c : MpfComponent) : Prop := c.isZero = true ∨ 0 ≤ c.distance

/-- `aligned_square` after decoding the exponent and zero flag. -/
def alignedSquare (W : Nat) (c : MpfComponent) : Nat :=
  if c.isZero = true ∨ c.distance < 0 ∨ (W : Int) ≤ c.distance then 0
  else (c.mantissa * c.mantissa) >>> (2 * c.distance.toNat)

/-- Numerator of the exact square in units of `eps^2 / 4^W`. A negative
distance scales up the numerator, and a positive distance scales up the
denominator. -/
def squareNumerator (c : MpfComponent) : Nat :=
  c.effectiveMantissa * c.effectiveMantissa * 4 ^ (-c.distance).toNat

def squareDenominator (c : MpfComponent) : Nat := 4 ^ c.distance.toNat

private theorem effectiveMantissa_lt (c : MpfComponent) (W : Nat)
    (hm : c.mantissa < 2 ^ W) : c.effectiveMantissa < 2 ^ W := by
  by_cases hz : c.isZero = true
  · simp only [effectiveMantissa, hz, ↓reduceIte, Nat.pow_pos (by decide : 0 < (2 : Nat))]
  · simpa only [effectiveMantissa, hz, Bool.false_eq_true, ↓reduceIte] using hm

theorem alignedSquare_eq_div (c : MpfComponent) (W : Nat) (hm : c.mantissa < 2 ^ W)
    (hg : c.guard) :
    c.alignedSquare W = c.effectiveMantissa * c.effectiveMantissa / c.squareDenominator := by
  by_cases hz : c.isZero = true
  · simp only [alignedSquare, hz, true_or, ↓reduceIte, effectiveMantissa, Nat.mul_zero,
      Nat.zero_div]
  have hd : 0 ≤ c.distance := hg.resolve_left hz
  have hn : ¬c.distance < 0 := Int.not_lt.mpr hd
  by_cases hc : (W : Int) ≤ c.distance
  · have hk : W ≤ c.distance.toNat := by omega
    have hp : 4 ^ W ≤ 4 ^ c.distance.toNat := Nat.pow_le_pow_right (by decide) hk
    have hs := Nat.lt_of_lt_of_le (sq_lt_bound c.mantissa W hm) hp
    simp only [alignedSquare, hz, Bool.false_eq_true, hn, hc, or_true, ↓reduceIte,
      effectiveMantissa, squareDenominator, Nat.div_eq_of_lt hs]
  · simp only [alignedSquare, hz, Bool.false_eq_true, hn, hc, or_self, ↓reduceIte,
      Nat.shiftRight_eq_div_pow, Nat.pow_mul, Nat.reducePow, effectiveMantissa, squareDenominator]

private theorem alignedSquare_lt (c : MpfComponent) (W : Nat) (hm : c.mantissa < 2 ^ W) :
    c.alignedSquare W < 4 ^ W := by
  unfold alignedSquare
  split
  · exact Nat.pow_pos (by decide)
  · exact Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) (sq_lt_bound c.mantissa W hm)

/-- The RTL's widened mantissa product and fixed-width shift count. -/
def alignedSquareBits (W shiftBits : Nat) (c : MpfComponent) : BitVec (2 * W) :=
  if c.isZero = true ∨ c.distance < 0 ∨ (W : Int) ≤ c.distance then 0
  else
    let m := BitVec.ofNat (2 * W) c.mantissa
    (m * m) >>> (BitVec.ofNat shiftBits (2 * c.distance.toNat)).toNat

theorem alignedSquareBits_toNat (c : MpfComponent) (W shiftBits : Nat)
    (hm : c.mantissa < 2 ^ W) (hbits : 2 * W ≤ 2 ^ shiftBits) :
    (c.alignedSquareBits W shiftBits).toNat = c.alignedSquare W := by
  unfold alignedSquareBits alignedSquare
  split
  · simp only [BitVec.ofNat_eq_ofNat, BitVec.toNat_ofNat, Nat.zero_mod]
  · rename_i h
    have hnear : ¬(W : Int) ≤ c.distance := fun hw => h (Or.inr (Or.inr hw))
    have hshift : 2 * c.distance.toNat < 2 ^ shiftBits := by omega
    have hw : 2 ^ W ≤ 2 ^ (2 * W) := Nat.pow_le_pow_right (by decide) (by omega)
    have hmwide := Nat.lt_of_lt_of_le hm hw
    have hsq : c.mantissa * c.mantissa < 2 ^ (2 * W) := by
      rw [Nat.pow_mul]
      exact sq_lt_bound c.mantissa W hm
    simp only [BitVec.toNat_ofNat, Nat.mod_eq_of_lt hshift, BitVec.toNat_ushiftRight,
      BitVec.toNat_mul, Nat.mod_eq_of_lt hmwide, Nat.mod_eq_of_lt hsq]

private theorem numerator_under_guard (c : MpfComponent) (hg : c.guard) :
    c.squareNumerator = c.effectiveMantissa * c.effectiveMantissa := by
  rcases hg with hz | hd
  · simp only [squareNumerator, effectiveMantissa, hz, ↓reduceIte, Nat.mul_zero, Nat.zero_mul]
  · have h : (-c.distance).toNat = 0 := by omega
    simp only [squareNumerator, h, Nat.pow_zero, Nat.mul_one]

private theorem guard_failure_reaches (c : MpfComponent) (W : Nat) (hW : 0 < W)
    (hn : c.Normalized W) (hs : c.isSpecial = false) (hg : ¬c.guard) :
    4 ^ W * c.squareDenominator ≤ c.squareNumerator := by
  have hz : c.isZero ≠ true := fun h => hg (Or.inl h)
  have hd : c.distance < 0 := Int.lt_of_not_ge (fun h => hg (Or.inr h))
  have hpos : 1 ≤ (-c.distance).toNat := by omega
  have hden : c.distance.toNat = 0 := by omega
  let d := (-c.distance).toNat
  have h := normalized_reaches c.mantissa W d hW (hn hs hz) hpos
  have hsq : 4 ^ W ≤ c.mantissa * c.mantissa * 4 ^ d := by
    calc
      4 ^ W = 2 ^ W * 2 ^ W := by rw [← Nat.mul_pow]
      _ ≤ (c.mantissa * 2 ^ d) * (c.mantissa * 2 ^ d) := Nat.mul_le_mul h h
      _ = c.mantissa * c.mantissa * 4 ^ d := by
        rw [show (4 : Nat) ^ d = 2 ^ d * 2 ^ d by rw [← Nat.mul_pow]]
        ac_rfl
  simpa only [squareDenominator, hden, Nat.pow_zero, Nat.mul_one, squareNumerator,
    effectiveMantissa, hz, Bool.false_eq_true, ↓reduceIte, ge_iff_le] using hsq

end MpfComponent

/-- The RTL predicate on decoded values, with exact integer intermediates. -/
def rtlBelow (W : Nat) (re im : MpfComponent) : Prop :=
  re.isSpecial = false ∧ im.isSpecial = false ∧ re.guard ∧ im.guard ∧
    re.alignedSquare W + im.alignedSquare W < 4 ^ W

/-- The strict squared magnitude comparison, with no flooring. -/
def exactBelow (W : Nat) (re im : MpfComponent) : Prop :=
  re.isSpecial = false ∧ im.isSpecial = false ∧
    re.squareNumerator * im.squareDenominator + im.squareNumerator * re.squareDenominator <
      4 ^ W * (re.squareDenominator * im.squareDenominator)

private theorem compare_under_guards (W : Nat) (re im : MpfComponent)
    (hr : re.mantissa < 2 ^ W) (hi : im.mantissa < 2 ^ W) (gr : re.guard) (gi : im.guard) :
    re.alignedSquare W + im.alignedSquare W < 4 ^ W ↔
      re.squareNumerator * im.squareDenominator + im.squareNumerator * re.squareDenominator <
        4 ^ W * (re.squareDenominator * im.squareDenominator) := by
  rw [re.alignedSquare_eq_div W hr gr, im.alignedSquare_eq_div W hi gi,
    re.numerator_under_guard gr, im.numerator_under_guard gi]
  exact magnitude_compare_exact W _ _ _ _ (re.effectiveMantissa_lt W hr) (im.effectiveMantissa_lt W hi)

/-- A small result from the checker is sound even with unnormalized mantissas. -/
theorem rtl_below_sound (W : Nat) (re im : MpfComponent)
    (hr : re.mantissa < 2 ^ W) (hi : im.mantissa < 2 ^ W) :
    rtlBelow W re im → exactBelow W re im := by
  rintro ⟨sr, si, gr, gi, hsum⟩
  exact ⟨sr, si, (compare_under_guards W re im hr hi gr gi).mp hsum⟩

private theorem exact_requires_left_guard (W : Nat) (re im : MpfComponent)
    (hW : 0 < W) (hn : re.Normalized W) (hexact : exactBelow W re im) : re.guard := by
  letI : Decidable re.guard := inferInstanceAs (Decidable (re.isZero = true ∨ 0 ≤ re.distance))
  by_cases hg : re.guard
  · exact hg
  have ⟨hs, _, hsum⟩ := hexact
  have h := re.guard_failure_reaches W hW hn hs hg
  have hb : 4 ^ W * (re.squareDenominator * im.squareDenominator) ≤
      re.squareNumerator * im.squareDenominator := by
    rw [← Nat.mul_assoc]
    exact Nat.mul_le_mul_right _ h
  omega

/-- With normalized finite nonzero words, the decoded RTL model agrees with
the exact strict comparison for either sign of each exponent distance. -/
theorem rtl_below_exact (W : Nat) (re im : MpfComponent) (hW : 0 < W)
    (hr : re.mantissa < 2 ^ W) (hi : im.mantissa < 2 ^ W)
    (nr : re.Normalized W) (ni : im.Normalized W) : rtlBelow W re im ↔ exactBelow W re im := by
  refine ⟨rtl_below_sound W re im hr hi, ?_⟩
  intro hexact
  have gr := exact_requires_left_guard W re im hW nr hexact
  have ⟨sr, si, hsum⟩ := hexact
  have hswap : exactBelow W im re := by
    refine ⟨si, sr, ?_⟩
    rwa [Nat.add_comm, Nat.mul_comm im.squareDenominator re.squareDenominator]
  have gi := exact_requires_left_guard W im re hW ni hswap
  exact ⟨sr, si, gr, gi, (compare_under_guards W re im hr hi gr gi).mpr hsum⟩

/-- The decoded RTL predicate with finite-width square, shift, and sum. -/
def rtlBelowBits (W shiftBits : Nat) (re im : MpfComponent) : Prop :=
  re.isSpecial = false ∧ im.isSpecial = false ∧ re.guard ∧ im.guard ∧
    let a := (re.alignedSquareBits W shiftBits).setWidth (2 * W + 1)
    let b := (im.alignedSquareBits W shiftBits).setWidth (2 * W + 1)
    a + b < BitVec.ofNat (2 * W + 1) (4 ^ W)

theorem rtl_below_bits_eq (W shiftBits : Nat) (re im : MpfComponent)
    (hbits : 2 * W ≤ 2 ^ shiftBits) (hr : re.mantissa < 2 ^ W) (hi : im.mantissa < 2 ^ W) :
    rtlBelowBits W shiftBits re im ↔ rtlBelow W re im := by
  have ha := re.alignedSquare_lt W hr
  have hb := im.alignedSquare_lt W hi
  have hsum : re.alignedSquare W + im.alignedSquare W < 2 ^ (2 * W + 1) := by
    rw [Nat.pow_succ, Nat.pow_mul]
    change re.alignedSquare W + im.alignedSquare W < 4 ^ W * 2
    omega
  have hbound : 4 ^ W < 2 ^ (2 * W + 1) := by
    have h : 0 < 4 ^ W := Nat.pow_pos (by decide)
    rw [Nat.pow_succ, Nat.pow_mul]
    change 4 ^ W < 4 ^ W * 2
    omega
  have hwidth : 2 * W ≤ 2 * W + 1 := by omega
  simp only [rtlBelowBits, rtlBelow, BitVec.lt_def, BitVec.toNat_add,
    BitVec.toNat_setWidth_of_le hwidth, re.alignedSquareBits_toNat W shiftBits hr hbits,
    im.alignedSquareBits_toNat W shiftBits hi hbits, BitVec.toNat_ofNat,
    Nat.mod_eq_of_lt hsum, Nat.mod_eq_of_lt hbound]

/-- Exact comparison in the fixed-width model for normalized decoded MPF. -/
theorem rtl_below_bits_exact (W shiftBits : Nat) (re im : MpfComponent)
    (hW : 0 < W) (hbits : 2 * W ≤ 2 ^ shiftBits)
    (hr : re.mantissa < 2 ^ W) (hi : im.mantissa < 2 ^ W)
    (nr : re.Normalized W) (ni : im.Normalized W) :
    rtlBelowBits W shiftBits re im ↔ exactBelow W re im :=
  (rtl_below_bits_eq W shiftBits re im hbits hr hi).trans (rtl_below_exact W re im hW hr hi nr ni)

/-- A small result from the fixed-width model is sound even with unnormalized
mantissas: the checker never reports "below" for a value that is not below. -/
theorem rtl_below_bits_sound (W shiftBits : Nat) (re im : MpfComponent)
    (hbits : 2 * W ≤ 2 ^ shiftBits) (hr : re.mantissa < 2 ^ W) (hi : im.mantissa < 2 ^ W) :
    rtlBelowBits W shiftBits re im → exactBelow W re im :=
  fun h => rtl_below_sound W re im hr hi ((rtl_below_bits_eq W shiftBits re im hbits hr hi).mp h)

/-- Field decode of one packed MPF word, as in `zeta_mpf_magnitude`: mantissa in
bits `[W-1:0]`, two's-complement exponent in the next `expW` bits, then the
sign, zero and special flags. `epsExp` is the `EPS_EXP` parameter. -/
def decodeMpf (W expW : Nat) (epsExp : Int) (word : BitVec (W + expW + 3)) : MpfComponent where
  mantissa := (word.extractLsb' 0 W).toNat
  distance := epsExp - (word.extractLsb' W expW).toInt
  isZero := word.getLsbD (W + expW + 1)
  isSpecial := word.getLsbD (W + expW + 2)

/-- The Z64 instance on packed 87-bit words (`WIDTH = 64`, `EXPW = 20`,
`SHIFT_WIDTH = $clog2(128) = 7`) for every `EPS_EXP`. Only normalization is
left as a hypothesis. -/
theorem z64_below_bits_exact (epsExp : Int) (re im : BitVec (64 + 20 + 3))
    (nr : (decodeMpf 64 20 epsExp re).Normalized 64)
    (ni : (decodeMpf 64 20 epsExp im).Normalized 64) :
    rtlBelowBits 64 7 (decodeMpf 64 20 epsExp re) (decodeMpf 64 20 epsExp im) ↔
      exactBelow 64 (decodeMpf 64 20 epsExp re) (decodeMpf 64 20 epsExp im) :=
  rtl_below_bits_exact 64 7 _ _ (by decide) (by decide)
    (re.extractLsb' 0 64).isLt (im.extractLsb' 0 64).isLt nr ni

/-- The Z64 checker is never optimistic, whatever the mantissas. -/
theorem z64_below_bits_sound (epsExp : Int) (re im : BitVec (64 + 20 + 3)) :
    rtlBelowBits 64 7 (decodeMpf 64 20 epsExp re) (decodeMpf 64 20 epsExp im) →
      exactBelow 64 (decodeMpf 64 20 epsExp re) (decodeMpf 64 20 epsExp im) :=
  rtl_below_bits_sound 64 7 _ _ (by decide) (re.extractLsb' 0 64).isLt (im.extractLsb' 0 64).isLt

end Zeta

/-! The build fails if a main theorem starts to depend on any other axiom. -/

/-- info: 'Zeta.rtl_below_bits_exact' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms Zeta.rtl_below_bits_exact

/-- info: 'Zeta.rtl_below_bits_sound' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in
#print axioms Zeta.rtl_below_bits_sound
