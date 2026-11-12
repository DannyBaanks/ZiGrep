import subprocess,sys,os,random
OLD=os.environ["ZGREP_OLD"]; NEW=sys.argv[1]
r=random.Random(int(sys.argv[2])); bad=0
words=["foo","bar","HIT","baz","x","kamikaze","ab","zz"]
for it in range(int(sys.argv[3])):
    size=r.randint(1_050_000,3_000_000)
    lines=[];n=0
    while n<size:
        l=" ".join(r.choice(words) for _ in range(r.randint(0,12))); lines.append(l); n+=len(l)+1
    b=bytearray(("\n".join(lines)+r.choice(["\n",""])).encode())
    for _ in range(r.choice([0,0,1,1,2,5])):
        b[r.randint(8200,len(b)-1)]=0
    if r.random()<0.2:  # NUL right before or inside a match
        k=b.find(b"HIT",r.randint(8200,len(b)-10))
        if k>0: b[k+r.choice([-1,0,1,2,3])]=0
    open("rn.txt","wb").write(b)
    pat=r.choice(["HIT","HIT kamikaze","ab","zz","kamikaze","bar baz","x x","HIT foo","o b"])
    for mode in (["-c"],["-n"],["-b","-n"],["--count-matches"],["-m","5","-n"],["-l"]):
        c=[*mode,"-F",pat,"rn.txt"]
        o=[subprocess.run([x,*c],capture_output=True,stdin=subprocess.DEVNULL,timeout=30) for x in (OLD,NEW)]
        if (o[0].returncode,o[0].stdout)!=(o[1].returncode,o[1].stdout): bad+=1; print("DIFF",it,c,o[0].stdout[:60],o[1].stdout[:60]); open(f"bad{bad}.txt","wb").write(b)
print("iters",sys.argv[3],"bad",bad)
