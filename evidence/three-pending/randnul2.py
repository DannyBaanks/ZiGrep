import subprocess,sys,os,random
OLD=os.environ["ZGREP_OLD"]; NEW=sys.argv[1]
r=random.Random(int(sys.argv[2])); bad=0; runs=0
words=["foo","bar","HIT","Hit","baz","x","kamikaze","KamiKaze","ab","zz","foobar"]
pats=[["-F","HIT"],["-i","-F","hit"],["-i","-F","hit kamikaze"],["-w","-F","foo"],["-w","-i","-F","hit"],
      ["-E","foo|bar"],["-E","HIT|zz"],["-i","-E","hit|baz"],["-E","HIT k[a-z]+"],["-E","foo(bar)?$"],
      ["-F","-e","ab","-e","zz"],["-E","^x"],["-E","kami.aze"],["-w","-E","foo|bar"],["-i","-E","kamikaze [hb]"]]
for it in range(int(sys.argv[3])):
    size=r.randint(1_050_000,2_500_000)
    lines=[];n=0
    while n<size:
        l=" ".join(r.choice(words) for _ in range(r.randint(0,12))); lines.append(l); n+=len(l)+1
    b=bytearray(("\n".join(lines)+r.choice(["\n",""])).encode())
    for _ in range(r.choice([0,0,1,1,2,5])):
        b[r.randint(8200,len(b)-1)]=0
    if r.random()<0.3:
        k=b.find(b"HIT",r.randint(8200,len(b)-10))
        if k>0: b[k+r.choice([-1,0,1,2,3,4,10])]=0
    open("rn2.txt","wb").write(b)
    p=r.choice(pats)
    for mode in (["-c"],["-n"],["-b"],["--count-matches"],["-m","5","-n"]):
        c=[*mode,*p,"rn2.txt"]; runs+=1
        o=[subprocess.run([x,*c],capture_output=True,stdin=subprocess.DEVNULL,timeout=60) for x in (OLD,NEW)]
        if (o[0].returncode,o[0].stdout)!=(o[1].returncode,o[1].stdout):
            bad+=1; print("DIFF",it,c,o[0].stdout[:60],o[1].stdout[:60]); open(f"bad2_{bad}.txt","wb").write(b)
print("runs",runs,"bad",bad)
