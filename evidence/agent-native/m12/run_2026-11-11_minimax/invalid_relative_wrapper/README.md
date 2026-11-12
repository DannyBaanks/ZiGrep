These five ZG records are INVALID as a measurement of ZiGrep. The logging
wrapper was passed as a relative path and the grep tool spawns it with
cwd = the searched directory, so every grep call failed (status error,
ziggrep_calls = 0) and the agent answered with its other tools. They are
kept as a record of the failure; the ZG runs were repeated with an absolute
wrapper path.
