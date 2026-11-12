import subprocess,sys,os
OLD=os.environ["ZGREP_OLD"]
NEW=sys.argv[1]
cases=[["-c","HIT"],["-n","HIT"],["-c","-F","-e","foo","-e","bar"],["-c","-E","HI.|z$"],["-n","-i","hit"],["-c","-w","foo"],["-l","HIT"],["-q","HIT"],["-m","3","-n","HIT"],["--count-matches","HIT"],["-c",""],["-c","-E","^"],["-n","-E","bar$"],["-b","HIT"],["--binary-files=binary","HIT"],["-c","-x","x"],["-c","-i","-E","hit|baz"],["-o","HIT"],["-v","-c","HIT"],["--json","-c","HIT"]]
bad=0;n=0
for f in ["n1","n2","n3","n4","n5","n6","n7"]:
    for c in cases:
        r=[subprocess.run([b,*c,f+".txt"],capture_output=True,stdin=subprocess.DEVNULL,timeout=30) for b in (OLD,NEW)]
        n+=1
        if (r[0].returncode,r[0].stdout,r[0].stderr)!=(r[1].returncode,r[1].stdout,r[1].stderr):
            bad+=1; print("DIFF",f,c,r[0].stdout[:80],r[1].stdout[:80])
print(f"cases={n} diff={bad}")
