# PRUEBAS.md — Medición Científica Cara a Cara (10 Corridas Reales Controladas)

> **Nota de Rigor Científico y Fe de Erratas:**
> En una medición preliminar previa, un error de entrecomillado en el script de python (`shell=True` sobre la ruta sin escapar `/home/danny/Development/ISyCo Git/...`) provocó que `/bin/sh` intentara ejecutar el directorio `/home/danny/Development/ISyCo` en lugar del binario `zigrep`, arrojando un fallo de permisos inmediato en ~2 ms que fue silenciado por `stderr=DEVNULL`.
> Esta versión corrige completamente el protocolo de medición: utiliza ejecución directa por `argv` sin shell, valida que el código de retorno sea exitoso (`0` o `1`), y registra las 10 corridas rotativas reales con evidencia respaldada por hash SHA-256 (`evidence/real_benchmarks_10runs.json`).

Medido en **Ubuntu 24.04 LTS (Kernel Linux x86_64, 12 hilos CPU, NVMe)**.

## 🏆 1. Resumen General de Medias (μ de 10 Corridas por Herramienta)

| # | Escenario de Prueba | `zigrep` (Kamikaze) | `zigrep --uring` | `ripgrep 14.1.0` | `GNU grep 3.11` | Speedup vs `rg` | Speedup vs `grep` |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | **Micro-árbol (corpus_50: 50 archivos, 1.64 MB)** | **9.88 ms** | 11.91 ms | 13.47 ms | 7.08 ms | **1.36×** | **0.72×** |
| 2 | **Árbol Medio (corpus_1000: 1,000 archivos, 32.8 MB)** | **23.41 ms** | 35.74 ms | 22.65 ms | 22.30 ms | **0.97×** | **0.95×** |
| 3 | **Árbol Sintético (synthetic: 254 archivos, 131 MB)** | **47.57 ms** | 69.92 ms | 37.93 ms | 51.56 ms | **0.80×** | **1.08×** |
| 4 | **Monorepo Real (assembly: 5,338 archivos, 655 MB)** | **85.31 ms** | 109.24 ms | 108.67 ms | 535.84 ms | **1.27×** | **6.28×** |
| 5 | **Regex DFA (pub\s+fn\s+ en assembly, 655 MB)** | **95.63 ms** | 120.05 ms | 120.33 ms | 1257.67 ms | **1.26×** | **13.15×** |
| 6 | **Early-Exit Silencioso -q (assembly, 655 MB)** | **3.11 ms** | 2.04 ms | 14.63 ms | 3.01 ms | **4.71×** | **0.97×** |
| 7 | **Files Without Match -L (assembly, 655 MB)** | **93.68 ms** | 110.85 ms | 125.32 ms | 718.61 ms | **1.34×** | **7.67×** |
| 8 | **Max Count -m 1 (assembly, 655 MB)** | **95.92 ms** | 117.71 ms | 126.65 ms | 678.69 ms | **1.32×** | **7.08×** |
| 9 | **Invert Match -v (assembly, 655 MB)** | **482.19 ms** | 514.64 ms | 500.22 ms | 1213.38 ms | **1.04×** | **2.52×** |
| 10 | **Multi-Repo Real-World (BRE \| + 4 Globs --include)** | **32.33 ms** | 35.67 ms | 23.90 ms | 68.88 ms | **0.74×** | **2.13×** |

---

## 🔬 2. Detalle Escenario por Escenario (Datos Crudos de las 10 Corridas)

### Escenario 1: Micro-árbol (corpus_50: 50 archivos, 1.64 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **9.88 ms** | 9.25 ms | 4.17 ms | 19.25 ms | 3.96 ms |
| **`zigrep --uring`** | **11.91 ms** | 12.56 ms | 4.29 ms | 16.97 ms | 4.34 ms |
| **`ripgrep 14.1.0`** | **13.47 ms** | 13.58 ms | 7.36 ms | 21.73 ms | 4.09 ms |
| **`GNU grep 3.11`** | **7.08 ms** | 7.09 ms | 3.00 ms | 13.49 ms | 3.31 ms |

* `zigrep`: `[9.41, 12.26, 10.06, 8.35, 6.91, 10.81, 8.45, 9.09, 19.25, 4.17]` ms
* `zigrep --uring`: `[16.97, 4.29, 12.46, 16.79, 14.38, 12.66, 11.21, 4.76, 11.73, 13.88]` ms
* `ripgrep`: `[15.7, 12.63, 8.64, 14.37, 12.8, 7.36, 15.64, 15.02, 21.73, 10.76]` ms
* `GNU grep`: `[5.49, 8.0, 3.2, 10.88, 13.49, 3.0, 4.54, 6.54, 8.05, 7.64]` ms

### Escenario 2: Árbol Medio (corpus_1000: 1,000 archivos, 32.8 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **23.41 ms** | 21.35 ms | 11.45 ms | 44.42 ms | 9.22 ms |
| **`zigrep --uring`** | **35.74 ms** | 35.60 ms | 23.46 ms | 45.53 ms | 5.88 ms |
| **`ripgrep 14.1.0`** | **22.65 ms** | 26.52 ms | 8.64 ms | 31.37 ms | 7.56 ms |
| **`GNU grep 3.11`** | **22.30 ms** | 19.62 ms | 17.39 ms | 35.04 ms | 6.81 ms |

* `zigrep`: `[11.45, 22.04, 44.42, 23.14, 16.0, 17.91, 26.99, 20.16, 31.32, 20.66]` ms
* `zigrep --uring`: `[33.47, 34.19, 45.53, 23.46, 32.11, 34.06, 37.98, 40.46, 39.13, 37.0]` ms
* `ripgrep`: `[26.8, 27.0, 26.24, 28.02, 22.03, 8.64, 31.37, 12.2, 16.91, 27.27]` ms
* `GNU grep`: `[19.86, 34.98, 21.68, 17.39, 18.81, 17.46, 19.51, 19.73, 35.04, 18.56]` ms

### Escenario 3: Árbol Sintético (synthetic: 254 archivos, 131 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **47.57 ms** | 47.61 ms | 34.20 ms | 57.50 ms | 8.47 ms |
| **`zigrep --uring`** | **69.92 ms** | 69.58 ms | 47.02 ms | 94.54 ms | 12.05 ms |
| **`ripgrep 14.1.0`** | **37.93 ms** | 36.97 ms | 27.42 ms | 51.35 ms | 6.79 ms |
| **`GNU grep 3.11`** | **51.56 ms** | 48.13 ms | 43.35 ms | 71.06 ms | 9.29 ms |

* `zigrep`: `[46.9, 57.5, 34.2, 37.53, 55.96, 54.75, 56.65, 48.32, 41.95, 41.98]` ms
* `zigrep --uring`: `[68.7, 73.0, 70.46, 68.2, 47.02, 94.54, 70.46, 78.83, 66.56, 61.45]` ms
* `ripgrep`: `[51.35, 39.1, 32.42, 32.17, 36.94, 42.12, 37.0, 27.42, 36.62, 44.14]` ms
* `GNU grep`: `[43.35, 43.51, 48.33, 71.06, 59.05, 48.5, 61.99, 44.73, 47.93, 47.17]` ms

### Escenario 4: Monorepo Real (assembly: 5,338 archivos, 655 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **85.31 ms** | 85.45 ms | 56.35 ms | 99.70 ms | 11.85 ms |
| **`zigrep --uring`** | **109.24 ms** | 104.88 ms | 95.25 ms | 133.16 ms | 11.07 ms |
| **`ripgrep 14.1.0`** | **108.67 ms** | 103.97 ms | 91.02 ms | 130.88 ms | 15.53 ms |
| **`GNU grep 3.11`** | **535.84 ms** | 543.50 ms | 490.76 ms | 591.99 ms | 30.31 ms |

* `zigrep`: `[56.35, 99.7, 82.59, 97.13, 82.43, 92.58, 86.78, 87.51, 84.12, 83.95]` ms
* `zigrep --uring`: `[110.68, 133.16, 118.67, 100.77, 102.84, 104.58, 105.17, 95.25, 117.34, 103.97]` ms
* `ripgrep`: `[91.02, 130.88, 106.98, 95.46, 128.92, 118.18, 95.61, 94.23, 100.96, 124.48]` ms
* `GNU grep`: `[501.52, 544.32, 490.76, 544.3, 561.85, 509.97, 542.71, 549.01, 591.99, 521.96]` ms

### Escenario 5: Regex DFA (pub\s+fn\s+ en assembly, 655 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **95.63 ms** | 95.73 ms | 80.30 ms | 108.69 ms | 7.53 ms |
| **`zigrep --uring`** | **120.05 ms** | 118.40 ms | 107.01 ms | 141.04 ms | 12.15 ms |
| **`ripgrep 14.1.0`** | **120.33 ms** | 118.68 ms | 104.94 ms | 141.13 ms | 12.90 ms |
| **`GNU grep 3.11`** | **1257.67 ms** | 1252.37 ms | 1231.07 ms | 1337.37 ms | 31.82 ms |

* `zigrep`: `[80.3, 99.73, 89.1, 108.69, 96.19, 95.26, 97.88, 94.65, 93.16, 101.35]` ms
* `zigrep --uring`: `[122.16, 113.04, 114.63, 133.26, 122.73, 107.18, 131.72, 107.74, 107.01, 141.04]` ms
* `ripgrep`: `[107.17, 130.78, 129.38, 111.72, 104.94, 116.23, 106.76, 134.09, 141.13, 121.12]` ms
* `GNU grep`: `[1256.41, 1236.33, 1252.65, 1277.83, 1337.37, 1264.22, 1252.1, 1234.61, 1231.07, 1234.07]` ms

### Escenario 6: Early-Exit Silencioso -q (assembly, 655 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **3.11 ms** | 1.81 ms | 1.02 ms | 7.05 ms | 2.19 ms |
| **`zigrep --uring`** | **2.04 ms** | 1.71 ms | 0.95 ms | 3.57 ms | 0.83 ms |
| **`ripgrep 14.1.0`** | **14.63 ms** | 13.70 ms | 8.45 ms | 25.97 ms | 5.74 ms |
| **`GNU grep 3.11`** | **3.01 ms** | 2.67 ms | 1.70 ms | 6.10 ms | 1.35 ms |

* `zigrep`: `[1.47, 4.44, 7.05, 1.58, 1.02, 6.1, 1.48, 1.74, 4.29, 1.88]` ms
* `zigrep --uring`: `[2.9, 1.72, 2.04, 1.46, 3.57, 1.7, 1.54, 1.52, 2.97, 0.95]` ms
* `ripgrep`: `[9.5, 23.06, 12.8, 8.45, 25.97, 10.63, 14.85, 11.06, 14.6, 15.39]` ms
* `GNU grep`: `[1.89, 2.56, 6.1, 2.79, 2.97, 3.75, 2.45, 4.14, 1.7, 1.78]` ms

### Escenario 7: Files Without Match -L (assembly, 655 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **93.68 ms** | 90.11 ms | 77.03 ms | 108.22 ms | 10.30 ms |
| **`zigrep --uring`** | **110.85 ms** | 111.49 ms | 94.32 ms | 124.67 ms | 9.45 ms |
| **`ripgrep 14.1.0`** | **125.32 ms** | 123.82 ms | 106.77 ms | 149.93 ms | 12.41 ms |
| **`GNU grep 3.11`** | **718.61 ms** | 701.53 ms | 670.58 ms | 843.05 ms | 55.75 ms |

* `zigrep`: `[90.01, 97.95, 107.66, 90.21, 108.22, 103.49, 84.82, 89.74, 77.03, 87.64]` ms
* `zigrep --uring`: `[116.54, 107.41, 110.87, 113.4, 121.09, 97.38, 110.7, 112.11, 124.67, 94.32]` ms
* `ripgrep`: `[127.41, 115.98, 131.57, 118.07, 122.97, 106.77, 117.11, 124.67, 138.7, 149.93]` ms
* `GNU grep`: `[670.58, 744.05, 686.89, 677.49, 672.98, 720.59, 716.17, 775.1, 843.05, 679.22]` ms

### Escenario 8: Max Count -m 1 (assembly, 655 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **95.92 ms** | 97.45 ms | 73.98 ms | 116.41 ms | 13.83 ms |
| **`zigrep --uring`** | **117.71 ms** | 113.03 ms | 90.66 ms | 157.62 ms | 18.05 ms |
| **`ripgrep 14.1.0`** | **126.65 ms** | 123.50 ms | 106.15 ms | 150.70 ms | 15.84 ms |
| **`GNU grep 3.11`** | **678.69 ms** | 671.31 ms | 627.42 ms | 775.08 ms | 41.36 ms |

* `zigrep`: `[73.98, 110.67, 93.65, 116.41, 97.07, 101.15, 104.32, 74.57, 97.82, 89.59]` ms
* `zigrep --uring`: `[112.85, 90.66, 112.08, 117.57, 104.1, 113.22, 157.62, 135.14, 112.46, 121.43]` ms
* `ripgrep`: `[111.41, 123.98, 120.34, 147.66, 123.01, 150.7, 106.15, 109.74, 132.49, 141.01]` ms
* `GNU grep`: `[655.07, 715.97, 673.82, 627.42, 684.1, 650.63, 668.8, 654.52, 775.08, 681.52]` ms

### Escenario 9: Invert Match -v (assembly, 655 MB)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **482.19 ms** | 473.70 ms | 432.25 ms | 563.69 ms | 41.88 ms |
| **`zigrep --uring`** | **514.64 ms** | 503.35 ms | 474.11 ms | 578.10 ms | 38.56 ms |
| **`ripgrep 14.1.0`** | **500.22 ms** | 481.16 ms | 432.26 ms | 607.00 ms | 54.10 ms |
| **`GNU grep 3.11`** | **1213.38 ms** | 1220.40 ms | 1159.30 ms | 1267.06 ms | 34.24 ms |

* `zigrep`: `[507.77, 563.69, 467.42, 535.47, 452.13, 482.52, 449.29, 479.98, 432.25, 451.38]` ms
* `zigrep --uring`: `[519.78, 544.96, 578.1, 573.78, 474.11, 482.87, 504.67, 502.04, 484.25, 481.83]` ms
* `ripgrep`: `[490.06, 512.11, 471.35, 432.26, 472.26, 500.11, 470.66, 466.04, 607.0, 580.35]` ms
* `GNU grep`: `[1220.32, 1190.0, 1226.3, 1220.49, 1234.55, 1247.39, 1159.3, 1201.9, 1166.5, 1267.06]` ms

### Escenario 10: Multi-Repo Real-World (BRE \| + 4 Globs --include)
| Herramienta | Media (μ) | Mediana | Mínimo | Máximo | Desv. Est. (σ) |
|---|---:|---:|---:|---:|---:|
| **`zigrep` (Kamikaze)** | **32.33 ms** | 34.67 ms | 16.17 ms | 47.39 ms | 10.55 ms |
| **`zigrep --uring`** | **35.67 ms** | 36.23 ms | 25.08 ms | 46.09 ms | 7.48 ms |
| **`ripgrep 14.1.0`** | **23.90 ms** | 22.60 ms | 16.80 ms | 32.26 ms | 5.97 ms |
| **`GNU grep 3.11`** | **68.88 ms** | 67.48 ms | 58.08 ms | 85.68 ms | 8.71 ms |

* `zigrep`: `[16.17, 34.64, 17.23, 46.82, 34.85, 35.99, 26.36, 47.39, 29.17, 34.7]` ms
* `zigrep --uring`: `[46.09, 25.08, 32.2, 36.5, 38.32, 27.99, 35.96, 41.96, 45.33, 27.25]` ms
* `ripgrep`: `[22.37, 16.8, 18.3, 18.93, 32.17, 31.61, 23.31, 20.39, 22.82, 32.26]` ms
* `GNU grep`: `[60.26, 64.24, 70.72, 58.08, 77.9, 74.73, 70.92, 63.36, 62.94, 85.68]` ms

---

## 🧬 Anexo A. Micro-Tree Fast Path vs Enjambre (medición dedicada, 2026-11-08)

Protocolo: `scripts/bench.zig` (rondas intercaladas y rotativas entre grupos,
3 rondas de calentamiento, salida a `/dev/null`), binario `ReleaseFast`
(`zig build -Doptimize=ReleaseFast`), host con carga externa (`loadavg` 11–17
durante la toma) — por eso las cifras absolutas suben respecto a la tabla
principal, pero **las comparaciones dentro de cada bloque sí son válidas**.

### A.1 Micro-árbol — `corpus_50` (50 archivos, 1.64 MB, 69 directorios), 15 corridas

| Herramienta | Mediana | Mínimo | Máximo | Media | σ | Ruta |
|---|---:|---:|---:|---:|---:|---|
| `GNU grep -rnIF` | **2.52 ms** | 1.96 ms | 3.13 ms | 2.58 ms | 0.32 ms | — |
| **`zigrep` (default → micro path)** | 3.13 ms | 2.46 ms | 3.90 ms | 3.17 ms | 0.40 ms | `micro_path=yes`, 0 hilos |
| `zigrep --force-swarm` | 3.18 ms | 2.86 ms | 4.09 ms | 3.43 ms | 0.42 ms | 12 hilos + walk de ignorados |
| `zigrep -j 1` | 3.32 ms | 2.61 ms | 4.20 ms | 3.31 ms | 0.37 ms | 1 hilo (pool) |
| `ripgrep -nF` | 5.28 ms | 4.30 ms | 6.81 ms | 5.42 ms | 0.77 ms | — |

Muestras crudas (ns):

* `GNU grep`: `[2447160, 3127332, 1955384, 2733890, 2861220, 2353924, 2686932, 2272862, 2819161, 2368642, 2517744, 2244158, 2507825, 2978381, 2779226]`
* `zigrep` (micro): `[3068370, 3022695, 2460125, 3489704, 2872432, 3182084, 2825402, 2646766, 3163178, 3395145, 3103767, 3133493, 3899476, 3699589, 3621312]`
* `zigrep --force-swarm`: `[3160764, 3690723, 3066647, 3756366, 4048307, 3959709, 3148271, 3080183, 3136389, 2859446, 3053322, 3488822, 4089645, 3184499, 3779049]`
* `zigrep -j 1`: `[3529218, 3618997, 3543245, 3444459, 3176655, 2606370, 3253419, 3332448, 3323081, 3263188, 2918819, 3336756, 2831705, 3239122, 4196196]`
* `ripgrep`: `[4809551, 6472033, 4744388, 6289929, 6809088, 4298097, 5277222, 4849385, 4490409, 5167104, 4883530, 5565605, 5949378, 5488910, 6205310]`

### A.2 El coste real de la micro path: búsqueda muda (sin formato de salida), 15 corridas

Con `-q` desaparece el coste de emitir/formatear líneas y queda sólo
arranque + E/S + búsqueda, que es exactamente donde la micro path elimina
trabajo (0 hilos, 0 `clone()`, 0 mutexes, sin walk de ignorados):

| Comando | Mediana | Media | σ |
|---|---:|---:|---:|
| **`zigrep -q` (micro path)** | **2.00 ms** | 1.98 ms | 0.43 ms |
| `zigrep --force-swarm -q` (12 hilos) | 3.35 ms | 3.51 ms | 0.58 ms |

⇒ **1.67× más rápido** que el enjambre en el modo donde el enjambre sólo
añade overhead.

### A.3 Árbol medio — `corpus_1000` (1.000 archivos, 32.8 MB), 10 corridas

| Herramienta | Mediana | Mínimo | Máximo | Media | σ |
|---|---:|---:|---:|---:|---:|
| `GNU grep -rnIF` | 11.91 ms | 10.86 ms | 12.61 ms | 11.88 ms | 0.58 ms |
| **`zigrep` (default: sondeo + enjambre)** | 6.82 ms | 5.92 ms | 7.17 ms | 6.70 ms | 0.41 ms |
| `zigrep --force-swarm` (enjambre puro) | 6.59 ms | 5.84 ms | 7.14 ms | 6.47 ms | 0.44 ms |
| `zigrep -j 1` | 28.69 ms | 27.12 ms | 33.63 ms | 28.87 ms | 1.85 ms |
| `ripgrep -nF` | 9.13 ms | 8.81 ms | 9.82 ms | 9.19 ms | 0.33 ms |

El **sondeo de tamaño cuesta +0.23 ms** (3.5 %) frente al enjambre puro:
la micro path mide el presupuesto con `statx` antes de leer un solo byte y
entrega el árbol al enjambre en cuanto lo ve demasiado grande, sin E/S
desperdiciada. `--force-swarm` elimina incluso ese coste.

### A.4 Verificación funcional del comportamiento

Árbol de prueba (`/tmp/opencode/igtest2/parent/child`), con un `.gitignore`
en el directorio **padre** que ignora `kid.txt`:

| Comando | Archivos escaneados | Resultado |
|---|---:|---|
| `zigrep --stats -F NEEDLE <ruta>` (default) | 1 | `kid.txt` **sí** se busca (walk ascendente omitido) |
| `zigrep --stats --force-swarm -F NEEDLE <ruta>` | 0 | `kid.txt` **no** se busca (comportamiento anterior restaurado) |
| `grep -rnIF NEEDLE <ruta>` (referencia GNU) | 1 | coincide con el default: GNU grep tampoco lee `.gitignore` |

Salida cruda:

```
# default (micro path)
kamikaze: dirs=1 files=1 bytes=13 matched_files=1 matched_lines=1 threads=12 micro_path=yes ...
/tmp/opencode/igtest2/parent/child/kid.txt:1:NEEDLE child

# --force-swarm (walk ascendente respetado)
kamikaze: dirs=1 files=0 bytes=0 matched_files=0 matched_lines=0 threads=12 micro_path=no ...
```
