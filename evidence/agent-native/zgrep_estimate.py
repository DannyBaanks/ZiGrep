"""Port EXACTO de `batch.estimateTokens` (src/batch.zig, M7: zgrep-classes-v1),
para que los diferenciales comprueben el presupuesto con el mismo numero que
usa zgrep. Si cambian los pesos en Zig, cambian aqui (y el test lo detecta)."""
EST_SCALE = 1.112 * 1.01
W_BYTES, W_DIGITS, W_PUNCT, W_SPACE_RUNS, W_NONASCII = 0.2413, 1.0526, 0.0954, 0.1128, 0.4598


def estimate(b: bytes) -> float:
    digits = punct = space_runs = nonascii = 0
    in_space = False
    for c in b:
        sp = c in (32, 9, 10, 13)
        if sp:
            if not in_space:
                space_runs += 1
        elif c >= 0x80:
            nonascii += 1
        elif 48 <= c <= 57:
            digits += 1
        elif not ((97 <= c <= 122) or (65 <= c <= 90) or c == 95):
            punct += 1
        in_space = sp
    return (W_BYTES * len(b) + W_DIGITS * digits + W_PUNCT * punct + W_SPACE_RUNS * space_runs
            + W_NONASCII * nonascii) * EST_SCALE
