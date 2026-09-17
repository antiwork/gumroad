# frozen_string_literal: true

module Marketing::MetricsStatistics
  module_function

  def proportion(successes, n)
    { n:, successes:, rate: n.zero? ? nil : successes.fdiv(n) }
  end

  def two_proportion(a, b)
    return if a[:n].zero? || b[:n].zero?

    pooled = (a[:successes] + b[:successes]).fdiv(a[:n] + b[:n])
    variance = pooled * (1 - pooled) * (1.0 / a[:n] + 1.0 / b[:n])
    return 1.0 if variance.zero?

    Math.erfc((a[:rate] - b[:rate]).abs / Math.sqrt(2 * variance))
  end

  def sample(values)
    n = values.size
    mean = n.zero? ? nil : values.sum.fdiv(n)
    variance = n < 2 ? nil : values.sum { |value| (value - mean)**2 }.fdiv(n - 1)
    { n:, amount_cents: mean, total_cents: values.sum, variance: }
  end

  def welch(a, b)
    return if a[:n] < 2 || b[:n] < 2

    va = a[:variance] / a[:n]
    vb = b[:variance] / b[:n]
    difference = (a[:amount_cents] - b[:amount_cents]).abs
    return difference.zero? ? 1.0 : 0.0 if (va + vb).zero?

    df = (va + vb)**2 / (va**2 / (a[:n] - 1) + vb**2 / (b[:n] - 1))
    t_squared = difference**2 / (va + vb)
    regularized_beta(df / (df + t_squared), df / 2.0, 0.5)
  end

  # Student's t two-sided tail; continued fraction avoids integrating a long tail.
  def regularized_beta(x, a, b)
    return 0.0 if x.zero?
    return 1.0 if x == 1
    return 1 - regularized_beta(1 - x, b, a) if x > (a + 1) / (a + b + 2)

    front = Math.exp(Math.lgamma(a + b).first - Math.lgamma(a).first - Math.lgamma(b).first + a * Math.log(x) + b * Math.log(1 - x))
    c = 1.0
    d = 1.0 / (1 - (a + b) * x / (a + 1))
    fraction = d
    1.upto(200) do |m|
      [m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m)),
       -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))].each do |coefficient|
        d = 1 + coefficient * d
        d = 1e-30 if d.abs < 1e-30
        c = 1 + coefficient / c
        c = 1e-30 if c.abs < 1e-30
        d = 1.0 / d
        delta = d * c
        fraction *= delta
        return (front * fraction / a).clamp(0.0, 1.0) if coefficient.negative? && (delta - 1).abs < 1e-12
      end
    end
    raise "Student t tail did not converge"
  end
end
