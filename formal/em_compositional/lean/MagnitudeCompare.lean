/-
Why the magnitude checker may drop fraction bits.

`zeta_mpf_magnitude` decides `|z| < eps` for `z = re + i*im` given as two MPF
words. In units of `eps^2 / 4^W` (W = mantissa width) a component with
mantissa `m` and exponent `k` steps below eps contributes `m^2 / 4^k`, and the
test is

    m_re^2 / 4^k_re + m_im^2 / 4^k_im < 4^W.

The RTL computes each quotient with a right shift, which floors it. The
theorems below show that the floored comparison equals the exact one, for
every width and every pair of shifts. JasperGold checks the same statement
on the 64-bit RTL (`../mag`); this file is the argument behind it, with no
width fixed. Lean 4 core only, no Mathlib.

    lean formal/em_compositional/lean/MagnitudeCompare.lean
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
    simpa using h
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

end Zeta
