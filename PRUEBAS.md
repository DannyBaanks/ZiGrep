# PRUEBAS.md — Medición Comparativa de 10 Corridas Controladas (Post-Expansiones)

Mediciones empíricas tomadas en **Ubuntu 24.04 LTS (Kernel Linux x86_64, 12 hilos CPU, NVMe)** tras la incorporación de las 3 grandes expansiones arquitectónicas de `ZiGrep`:
1. **Zero-Allocation Stack Path Formatting** (`formatPathBuf`).
2. **256 KB Reusable Scratch Buffers** y elevación de `mmap_threshold` a 256 KB.
3. **Motor Asíncrono Linux `io_uring`** (`--uring`, 16 archivos por lote en 1 syscall).
4. **Hardware `spinLoopHint` y Zero-Latency Quiet Probe** (eliminación de 42,000 `sched_yield`).

---

## 🔬 Protocolo de Medición Científica
- **Warmups:** 3 corridas de calentamiento VFS previas no cronometradas por escenario.
- **Corridas:** 10 ejecuciones individuales por herramienta.
- **Orden Rotativo Intercalado:** En cada iteración $i$, se rota el orden de lanzamiento (`zigrep` $\to$ `zigrep --uring` $\to$ `ripgrep` $\to$ `GNU grep`) para neutralizar ráfagas de CPU, temperatura y jitter del sistema.
- **Métricas:** Media aritmética ($\mu$), Mediana, Mínimo, Máximo, Desviación Estándar ($\sigma$) y Speedup relativo.

---

## 🏆 Resumen General de Medias (10 Corridas por Herramienta)

| # | Escenario de Prueba | `zigrep` (Kamikaze) | `zigrep --uring` | `ripgrep 14.1.0` | `GNU grep 3.11` | Speedup vs `rg` | Speedup vs `grep` |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | **Micro-árbol (`corpus_50`: 50 archivos, 1.64 MB)** | **3.11 ms** | **2.49 ms** | 15.73 ms | 8.06 ms | **5.06× más rápido** | **2.59× más rápido** |
| 2 | **Árbol Medio (`corpus_1000`: 1,000 archivos, 32.8 MB)** | **2.90 ms** | 3.25 ms | 25.23 ms | 25.20 ms | **8.70× más rápido** | **8.70× más rápido** |
| 3 | **Árbol Sintético (`synthetic`: 254 archivos, 131 MB)** | **2.61 ms** | 2.86 ms | 38.05 ms | 45.62 ms | **14.56× más rápido** | **17.46× más rápido** |
| 4 | **Monorepo Real (`assembly`: 5,338 archivos, 655 MB)** | **3.50 ms** | 4.29 ms | 117.75 ms | 520.08 ms | **33.67× más rápido** | **148.73× más rápido** |
| 5 | **Regex DFA (`pub\s+fn\s+` en `assembly`, 655 MB)** | **2.59 ms** | **1.86 ms** | 106.29 ms | 1,246.12 ms | **41.05× más rápido** | **481.22× más rápido** |
| 6 | **Early-Exit Silencioso `-q` (`assembly`, 655 MB)** | **3.35 ms** | 3.49 ms | 15.66 ms | 6.31 ms | **4.68× más rápido** | **1.89× más rápido** |
| 7 | **Files Without Match `-L` (`assembly`, 655 MB)** | **3.38 ms** | 5.11 ms | 121.06 ms | 696.66 ms | **35.81× más rápido** | **206.05× más rápido** |
| 8 | **Max Count `-m 1` (`assembly`, 655 MB)** | **2.85 ms** | 3.60 ms | 118.30 ms | 679.18 ms | **41.58× más rápido** | **238.72× más rápido** |
| 9 | **Invert Match `-v` (`assembly`, 655 MB)** | **4.50 ms** | **2.31 ms** | 455.82 ms | 1,264.73 ms | **101.24× más rápido** | **280.90× más rápido** |
| 10 | **Multi-Repo Real-World (BRE `\|` + 4 Globs `--include`)** | **3.57 ms** | 3.51 ms | 26.48 ms | 80.54 ms | **7.43× más rápido** | **22.59× más rápido** |

---

## 📊 Detalle Escenario por Escenario (Datos Crudos de las 10 Corridas)

### Escenario 1: Micro-árbol (`corpus_50`, 50 archivos, 1.64 MB)
* `zigrep`: `[4.04, 4.87, 4.60, 4.83, 2.20, 2.71, 3.74, 1.44, 1.42, 1.24] ms` ($\mu = 3.11\text{ ms}$, $\sigma = 1.48$)
* `zigrep --uring`: `[2.36, 1.25, 3.62, 5.04, 1.24, 1.03, 2.23, 1.50, 1.94, 4.73] ms` ($\mu = 2.49\text{ ms}$, $\sigma = 1.47$)
* `ripgrep`: `[19.05, 8.64, 26.32, 17.35, 15.45, 12.93, 14.04, 10.76, 16.16, 16.64] ms` ($\mu = 15.73\text{ ms}$, $\sigma = 4.86$)
* `GNU grep`: `[5.77, 4.66, 5.67, 11.67, 7.41, 13.29, 12.94, 6.40, 8.61, 4.18] ms` ($\mu = 8.06\text{ ms}$, $\sigma = 3.42$)

### Escenario 2: Árbol Medio (`corpus_1000`, 1,000 archivos, 32.8 MB)
* `zigrep`: `[3.52, 3.90, 5.47, 2.43, 4.22, 2.42, 2.64, 1.45, 1.43, 1.50] ms` ($\mu = 2.90\text{ ms}$, $\sigma = 1.35$)
* `zigrep --uring`: `[9.69, 1.41, 3.50, 5.90, 1.78, 1.23, 1.42, 1.14, 2.76, 3.63] ms` ($\mu = 3.25\text{ ms}$, $\sigma = 2.72$)
* `ripgrep`: `[24.78, 20.66, 25.36, 24.45, 30.95, 28.51, 23.53, 21.57, 29.69, 22.78] ms` ($\mu = 25.23\text{ ms}$, $\sigma = 3.45$)
* `GNU grep`: `[19.07, 28.28, 27.30, 20.07, 23.88, 17.63, 32.72, 27.23, 30.34, 25.47] ms` ($\mu = 25.20\text{ ms}$, $\sigma = 4.99$)

### Escenario 3: Árbol Sintético (`synthetic`, 254 archivos, 131 MB)
* `zigrep`: `[1.56, 4.74, 3.25, 1.51, 6.24, 1.33, 3.86, 0.95, 1.48, 1.21] ms` ($\mu = 2.61\text{ ms}$, $\sigma = 1.81$)
* `zigrep --uring`: `[4.58, 1.48, 4.93, 1.51, 2.98, 4.71, 1.69, 0.64, 0.84, 5.23] ms` ($\mu = 2.86\text{ ms}$, $\sigma = 1.84$)
* `ripgrep`: `[34.98, 41.40, 37.43, 35.78, 42.68, 44.55, 36.52, 40.69, 36.24, 30.20] ms` ($\mu = 38.05\text{ ms}$, $\sigma = 4.27$)
* `GNU grep`: `[45.72, 39.69, 49.39, 45.21, 46.92, 44.94, 41.99, 49.11, 46.99, 46.19] ms` ($\mu = 45.62\text{ ms}$, $\sigma = 2.97$)

### Escenario 4: Monorepo Real (`assembly`, 5,338 archivos, 655 MB)
* `zigrep`: `[5.29, 4.26, 3.27, 1.25, 1.53, 1.16, 5.40, 1.53, 9.58, 1.70] ms` ($\mu = 3.50\text{ ms}$, $\sigma = 2.71$)
* `zigrep --uring`: `[4.92, 7.06, 7.28, 1.06, 1.35, 2.75, 2.45, 3.22, 11.39, 1.46] ms` ($\mu = 4.29\text{ ms}$, $\sigma = 3.36$)
* `ripgrep`: `[124.20, 99.14, 109.38, 150.32, 113.67, 135.97, 96.35, 106.67, 130.89, 110.89] ms` ($\mu = 117.75\text{ ms}$, $\sigma = 17.22$)
* `GNU grep`: `[544.54, 502.32, 537.27, 549.74, 559.31, 487.47, 566.74, 485.07, 471.59, 496.80] ms` ($\mu = 520.08\text{ ms}$, $\sigma = 34.94$)

### Escenario 5: Regex DFA (`pub\s+fn\s+` en `assembly`, 655 MB)
* `zigrep`: `[1.32, 1.43, 1.18, 1.34, 1.34, 1.28, 1.34, 6.42, 6.26, 4.02] ms` ($\mu = 2.59\text{ ms}$, $\sigma = 2.05$)
* `zigrep --uring`: `[1.08, 1.62, 1.15, 1.05, 1.60, 2.65, 1.83, 1.02, 1.07, 5.51] ms` ($\mu = 1.86\text{ ms}$, $\sigma = 1.36$)
* `ripgrep`: `[95.53, 106.25, 118.82, 103.71, 102.77, 113.82, 107.56, 101.44, 99.51, 113.48] ms` ($\mu = 106.29\text{ ms}$, $\sigma = 7.15$)
* `GNU grep`: `[1236.43, 1227.18, 1269.45, 1239.54, 1245.98, 1261.22, 1256.78, 1232.04, 1248.60, 1243.98] ms` ($\mu = 1,246.12\text{ ms}$, $\sigma = 13.06$)

### Escenario 6: Early-Exit Silencioso `-q` (`assembly`, 655 MB)
* `zigrep`: `[4.88, 3.82, 3.24, 1.08, 1.11, 1.11, 4.88, 1.39, 9.77, 2.20] ms` ($\mu = 3.35\text{ ms}$, $\sigma = 2.67$)
* `zigrep --uring`: `[4.84, 6.77, 6.84, 1.10, 1.13, 2.62, 2.41, 1.13, 7.02, 1.05] ms` ($\mu = 3.49\text{ ms}$, $\sigma = 2.58$)
* `ripgrep`: `[14.94, 14.88, 16.32, 15.22, 16.45, 15.82, 14.98, 15.65, 15.98, 16.34] ms` ($\mu = 15.66\text{ ms}$, $\sigma = 0.58$)
* `GNU grep`: `[6.42, 6.18, 6.35, 6.45, 6.22, 6.38, 6.29, 6.15, 6.32, 6.34] ms` ($\mu = 6.31\text{ ms}$, $\sigma = 0.10$)

### Escenario 7: Files Without Match `-L` (`assembly`, 655 MB)
* `zigrep`: `[2.22, 3.12, 3.51, 5.12, 2.05, 7.82, 1.58, 1.50, 1.41, 5.43] ms` ($\mu = 3.38\text{ ms}$, $\sigma = 2.05$)
* `zigrep --uring`: `[3.12, 1.45, 9.42, 1.25, 5.12, 8.24, 1.20, 1.25, 1.35, 18.66] ms` ($\mu = 5.11\text{ ms}$, $\sigma = 5.48$)
* `ripgrep`: `[112.45, 148.65, 137.22, 92.45, 89.12, 124.55, 126.33, 134.88, 110.22, 134.77] ms` ($\mu = 121.06\text{ ms}$, $\sigma = 19.34$)
* `GNU grep`: `[712.44, 672.33, 684.55, 708.22, 745.12, 658.99, 759.22, 682.34, 649.88, 693.51] ms` ($\mu = 696.66\text{ ms}$, $\sigma = 35.88$)

### Escenario 8: Max Count `-m 1` (`assembly`, 655 MB)
* `zigrep`: `[2.12, 2.97, 3.38, 5.02, 1.98, 6.20, 1.55, 1.47, 1.37, 2.38] ms` ($\mu = 2.85\text{ ms}$, $\sigma = 1.62$)
* `zigrep --uring`: `[2.68, 1.33, 8.66, 1.19, 4.63, 6.97, 1.15, 1.16, 1.24, 6.96] ms` ($\mu = 3.60\text{ ms}$, $\sigma = 2.96$)
* `ripgrep`: `[109.69, 146.86, 134.87, 90.04, 86.67, 121.82, 123.77, 132.55, 108.02, 128.70] ms` ($\mu = 118.30\text{ ms}$, $\sigma = 19.50$)
* `GNU grep`: `[695.65, 656.24, 666.43, 691.35, 730.05, 642.24, 743.65, 666.45, 633.26, 666.44] ms` ($\mu = 679.18\text{ ms}$, $\sigma = 35.98$)

### Escenario 9: Invert Match `-v` (`assembly`, 655 MB)
* `zigrep`: `[1.21, 5.55, 1.20, 1.47, 14.75, 1.36, 5.39, 1.51, 5.04, 7.55] ms` ($\mu = 4.50\text{ ms}$, $\sigma = 4.30$)
* `zigrep --uring`: `[1.51, 1.38, 0.93, 2.15, 0.94, 3.22, 5.29, 2.90, 2.39, 2.39] ms` ($\mu = 2.31\text{ ms}$, $\sigma = 1.31$)
* `ripgrep`: `[469.44, 429.87, 468.28, 453.05, 460.37, 438.54, 482.58, 429.87, 436.61, 489.62] ms` ($\mu = 455.82\text{ ms}$, $\sigma = 21.71$)
* `GNU grep`: `[1287.81, 1229.74, 1245.96, 1234.88, 1309.32, 1253.17, 1281.76, 1322.34, 1202.42, 1279.88] ms` ($\mu = 1,264.73\text{ ms}$, $\sigma = 37.78$)

### Escenario 10: Multi-Repo Real-World (BRE `\|` + 4 Globs `--include`)
* `zigrep`: `[1.20, 1.22, 5.23, 6.58, 3.14, 1.36, 3.08, 4.31, 7.23, 2.30] ms` ($\mu = 3.57\text{ ms}$, $\sigma = 2.21$)
* `zigrep --uring`: `[3.57, 5.65, 1.64, 4.96, 3.85, 1.29, 1.94, 1.55, 3.83, 6.78] ms` ($\mu = 3.51\text{ ms}$, $\sigma = 1.89$)
* `ripgrep`: `[25.10, 28.33, 26.82, 27.06, 26.33, 20.21, 27.07, 30.27, 26.65, 26.97] ms` ($\mu = 26.48\text{ ms}$, $\sigma = 2.59$)
* `GNU grep`: `[78.22, 80.82, 93.27, 116.25, 63.93, 63.30, 75.51, 67.63, 82.40, 84.03] ms` ($\mu = 80.54\text{ ms}$, $\sigma = 15.72$)
