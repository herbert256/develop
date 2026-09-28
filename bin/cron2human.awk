# cron2human.awk — translate a Quartz 6-field cron expression to plain English.
#
# Shared by bin/analyses/reports/uc3-polling.sh (the UC3 tab cron table) and
# bin/transfer/reports/details.sh (the Subscription detail-page Summary).
# Deterministic — no AI, no token cost, works on a fresh clone.
#
# Usage:  awk -F'\t' [-v CF=<cron-field>] -f bin/cron2human.awk
#   Reads TAB-separated rows; CF names the cron column (default: the LAST
#   field). The cron may hold SEVERAL expressions, one per line — jq's @tsv
#   renders the newline as a literal \n. Replaces the cron field with the
#   display form (its lines rejoined with \x1f) and APPENDS the human text
#   (per-line translations joined with "; "). So:
#     CF=3  "name<TAB>proto<TAB>cron"  ->  "name<TAB>proto<TAB>disp<TAB>human"
#     CF=2  "name<TAB>cron"            ->  "name<TAB>disp<TAB>human"
#
# A Quartz cron is: seconds minutes hours day-of-month month day-of-week.
# Keep POSIX-awk (mawk-safe).
function pad(n){ return sprintf("%02d", n+0) }
function hh(h){ return pad(h) ":00" }
function hm(h,m){ return pad(h) ":" pad(m) }   # hour:minute — a range endpoint at its real fire minute
function dname(n,   D){ split("Monday Tuesday Wednesday Thursday Friday Saturday Sunday",D," "); return D[n] }
function dshort(n,   D){ split("Mon Tue Wed Thu Fri Sat Sun",D," "); return D[n] }
function dnum(s,   M,n){ M["MON"]=1;M["TUE"]=2;M["WED"]=3;M["THU"]=4;M["FRI"]=5;M["SAT"]=6;M["SUN"]=7
  # numeric DOW uses the QUARTZ convention: 1=SUN … 7=SAT (0 tolerated as
  # Sunday), mapped here onto the internal 1=Mon … 7=Sun the name tables use
  if(s in M) return M[s]; if(s ~ /^[0-9]+$/){ n=s+0; return (n<=1?7:n-1) }; return 0 }
# one cron list SEGMENT into the set S over lo..hi: "*", "N", "A-B", "A/S",
# "*/S", "A-B/S"; a range whose end lies below its start WRAPS (Quartz:
# hours "22-2" = 22 23 0 1 2). Returns 0 when the segment does not parse.
# 2026-09-28 (the bug hunt): every field parser read "8-18/2" as 8 to 18 and
# a wrapped range as nothing; cron-observed.awk carries the same function.
function segset(seg,lo,hi,S,   a,b,x,st,k,n){
  st=1
  if(index(seg,"/")){ n=split(seg,a,"/"); if(n!=2||a[2]!~/^[0-9]+$/||a[2]+0<1) return 0; st=a[2]+0; seg=a[1] }
  if(seg=="*"||seg=="?"){ b=lo; x=hi }
  else if(seg ~ /^[0-9]+$/){ b=seg+0; x=(st>1 ? hi : b) }
  else if(seg ~ /^[0-9]+-[0-9]+$/){ split(seg,a,"-"); b=a[1]+0; x=a[2]+0 }
  else return 0
  if(b<lo||b>hi||x<lo||x>hi) return 0
  if(x>=b){ for(k=b;k<=x;k+=st) S[k]=1; return 1 }
  n=0; for(k=b;k<=hi;k++){ if(n%st==0) S[k]=1; n++ }
  for(k=lo;k<=x;k++){ if(n%st==0) S[k]=1; n++ }
  return 1 }
function ordw(n,   W){ split("first second third fourth fifth",W," "); return (n>=1&&n<=5 ? W[n] : n "th") }
function dayphrase(dow,   parts,np,i,seg,a,b,x,set,k,cnt,keys,mn,mx,j,out){
  if(dow=="*"||dow=="?"||dow=="") return ""
  # Quartz specials: "6#3"/"FRI#3" the third Friday, "6L"/"FRIL" the last
  # Friday of the month, a lone "L" = 7 = Saturday
  if(dow ~ /^[0-9A-Z]+#[1-5]$/){ split(dow,a,"#"); k=dnum(a[1]); if(k) return "on the " ordw(a[2]+0) " " dname(k); return "on day-of-week " dow }
  if(dow ~ /^[0-9A-Z]+L$/ && dow!="L"){ k=dnum(substr(dow,1,length(dow)-1)); if(k) return "on the last " dname(k); return "on day-of-week " dow }
  if(dow=="L") dow="SAT"
  np=split(dow,parts,",")
  for(i=1;i<=np;i++){ seg=parts[i]
    # a range walks the week from its first day to its last, WRAPPING past
    # Sunday: the Quartz numbers run SUN(1)..SAT(7), so "1-5" is Sunday to
    # Thursday and ends BELOW its start in the internal Mon..Sun order, as
    # does "FRI-MON" (2026-09-28 fix: both read as every day)
    if(seg ~ /-/){ split(seg,a,"-"); b=dnum(a[1]); x=dnum(a[2])
      if(b&&x){ if(b<=x) for(j=b;j<=x;j++) set[j]=1; else { for(j=b;j<=7;j++) set[j]=1; for(j=1;j<=x;j++) set[j]=1 } } }
    else { k=dnum(seg); if(k) set[k]=1 } }
  cnt=0; for(k=1;k<=7;k++) if(k in set) keys[++cnt]=k
  if(cnt==0||cnt==7) return ""
  if(cnt==5 && set[1]&&set[2]&&set[3]&&set[4]&&set[5]) return "on workdays"
  if(cnt==2 && set[6]&&set[7]) return "at weekends"
  mn=keys[1]; mx=keys[cnt]
  if(cnt==1) return "on " dname(mn)   # a single day is not a range — "on Monday", never "on Monday to Monday"
  if(mx-mn+1==cnt) return "on " dname(mn) " to " dname(mx)
  # ONE run around the week's end ("Sunday to Thursday"): exactly one day
  # starts a run, and the run from it covers every chosen day
  j=0; for(k=1;k<=7;k++) if((k in set) && !(((k+5)%7+1) in set)){ j++; b=k }
  if(j==1){ x=b; for(k=1;k<cnt;k++) x=x%7+1; return "on " dname(b) " to " dname(x) }
  out=""; for(i=1;i<=cnt;i++) out=out (out==""?"":", ") dshort(keys[i]); return "on " out
}
# a set of numbers (S[k]=1 over lo..hi) -> "1 to 7, 15 and 20 to 25": runs
# of three or more collapse to "A to B", shorter runs stay single values, the
# last item joins with "and"; the names table NM (optional) replaces each
# number by its name
function runtext(S,lo,hi,NM,   k,a,b,P,n,i,t){ n=0; k=lo
  while(k<=hi){ if(!(k in S)){ k++; continue }
    a=k; while((k+1) in S && k+1<=hi) k++; b=k
    if(b-a>=2) P[++n]=(NM[a]!=""?NM[a]:a) " to " (NM[b]!=""?NM[b]:b)
    else { P[++n]=(NM[a]!=""?NM[a]:a); if(b>a) P[++n]=(NM[b]!=""?NM[b]:b) }
    k++ }
  t=""; for(i=1;i<=n;i++) t=t (i==1 ? "" : (i==n ? " and " : ", ")) P[i]
  return t }
# day-of-month (Quartz field 4), SEVERAL days -> "on days 1 to 7" | "every 5
# days from day 1" | "" (every day); the one-day forms (the 1st, L, LW, L-n,
# nW) are domone's. Until 2026-09-23 the field was ignored, so
# "0 0 8 1-7 * ?" read as a plain "Daily at 08:00" (Herbert's report).
function domphrase(fld,   a,np,parts,i,k,S,cnt,NM,keys,st,ok){
  if(fld=="*"||fld=="?"||fld=="") return ""
  if(fld ~ /^([0-9]+|\*)\/[0-9]+$/){ split(fld,a,"/"); return "every " (a[2]+0) " days from day " (a[1]=="*" ? 1 : a[1]+0) }
  split("",S)
  np=split(fld,parts,",")
  for(i=1;i<=np;i++) if(!segset(parts[i],1,31,S)) return "on day-of-month " fld
  cnt=0; for(k=1;k<=31;k++) if(k in S) keys[++cnt]=k
  if(cnt==0||cnt==31) return ""
  if(cnt==1) return "on the " ordn(keys[1])
  # a uniform step through three or more days ("1-31/2"): the step, not the list
  st=keys[2]-keys[1]; ok=(st>1 && cnt>=3); for(i=3;i<=cnt;i++) if(keys[i]-keys[i-1]!=st) ok=0
  if(ok) return "every " st " days from day " keys[1] (keys[cnt]+st<=31 ? " to day " keys[cnt] : "")
  return "on days " runtext(S,1,31,NM)
}
function ordn(n,   r){ n+=0; r=n%100; if(r>=11&&r<=13) return n "th"; r=n%10
  return n (r==1 ? "st" : (r==2 ? "nd" : (r==3 ? "rd" : "th"))) }
# ONE day a month (2026-09-23, Herbert: "make it more clear") -> its noun,
# "the 1st" | "the last day" | "the 2nd-last day" (L-1) | "the last weekday" |
# "the weekday nearest the 15th"; "" when the field picks several days. The
# caller words these as "Monthly on the 1st at 08:00", not "Daily at 08:00
# on day 1 for every month".
function domone(fld,   n){
  if(fld ~ /^[0-9]+$/) return "the " ordn(fld)
  if(fld=="L") return "the last day"
  if(fld=="LW") return "the last weekday"
  if(fld ~ /^L-[0-9]+$/){ n=substr(fld,3)+0; return (n==0 ? "the last day" : "the " ordn(n+1) "-last day") }
  if(fld ~ /^[0-9]+W$/) return "the weekday nearest the " ordn(substr(fld,1,length(fld)-1))
  if(fld ~ /^[0-9,-]+$/){ n=domphrase(fld); if(n ~ /^on the /) return substr(n,4) }   # "5-5"
  return ""
}
function mnum(s,   M,i){ split("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC",M," ")
  for(i=1;i<=12;i++) if(s==M[i]) return i
  if(s ~ /^[0-9]+$/ && s+0>=1 && s+0<=12) return s+0; return 0 }
# month (Quartz field 5) -> "all:" | "in:January to March" | "in:January, July"
# | "step:every 3 months from January" | "raw:<field>" (unparsable)
function monset(fld,   M,a,np,parts,i,seg,b,x,k,S,cnt){
  split("January February March April May June July August September October November December",M," ")
  if(fld=="*"||fld=="?"||fld=="") return "all:"
  if(fld ~ /^([0-9A-Z]+|\*)\/[0-9]+$/){ split(fld,a,"/"); k=(a[1]=="*" ? 1 : mnum(a[1])); if(k) return "step:every " (a[2]+0) " months from " M[k]; return "raw:" fld }
  np=split(fld,parts,",")
  for(i=1;i<=np;i++){ seg=parts[i]
    if(seg ~ /-/){ split(seg,a,"-"); b=mnum(a[1]); x=mnum(a[2]); if(!b||!x) return "raw:" fld; for(k=b;k<=x;k++) S[k]=1 }
    else { k=mnum(seg); if(!k) return "raw:" fld; S[k]=1 } }
  cnt=0; for(k=1;k<=12;k++) if(k in S) cnt++
  if(cnt==0||cnt==12) return "all:"
  return "in:" runtext(S,1,12,M)
}
# the months as a trailing phrase -> "in January to March" | "" (every
# month). DOM set -> "for every month" when the month field is open, so a
# day-of-month schedule always says which months it covers.
function monphrase(fld,hasdom,   m,k,t){
  m=monset(fld); k=substr(m,1,index(m,":")-1); t=substr(m,index(m,":")+1)
  if(k=="all") return (hasdom ? "for every month" : "")
  if(k=="step") return t
  return "in " (k=="raw" ? "month " : "") t
}
# a numeric cron field -> "all" | "one:V" | "range:A:B" | "step:N:FIRST" |
# "list:v,v,.." | "raw:" (unparsable)  (cycle 60|24). Every form goes through
# segset, so "30/15" is the list 30,45 and "2/6" the step 6 from 2 (2026-09-28
# fix: both read as a plain step, the offset and the stop lost)
function fieldinfo(fld,cycle,   parts,np,i,set,k,cnt,keys,mn,mx,step,ok,out){
  if(fld=="*"||fld=="?") return "all"
  split("",set)
  np=split(fld,parts,",")
  for(i=1;i<=np;i++) if(!segset(parts[i],0,cycle-1,set)) return "raw:"
  cnt=0; for(k=0;k<cycle;k++) if(k in set) keys[++cnt]=k
  if(cnt==0||cnt==cycle) return "all"
  if(cnt==1) return "one:" keys[1]
  mn=keys[1]; mx=keys[cnt]
  if(mx-mn+1==cnt) return "range:" mn ":" mx
  step=keys[2]-keys[1]; ok=1; for(i=2;i<=cnt;i++) if(keys[i]-keys[i-1]!=step) ok=0
  if(ok && step>0 && mn<step && mx>=cycle-step) return "step:" step ":" mn
  out=""; for(i=1;i<=cnt;i++) out=out (out==""?"":",") keys[i]
  # an HOUR field stepping through a window ("8-18/2"): the step, the window
  # and the plain list for the phrasings that need the hours themselves
  if(cycle==24 && ok && step>1 && cnt>=3) return "every:" step ":" mn ":" mx ":" out
  return "list:" out
}
function hourlist(hv,   n,HL,i,t){ n=split(hv,HL,","); t=""; for(i=1;i<=n;i++) t=t (t==""?"":", ") hh(HL[i]); return t }
# An hour LIST with runs of consecutive hours (2026-09-13, user request:
# "0 0,10,20,30,40,50 0,8-23 * * ?" spelled out all sixteen hours): each run
# becomes a window from its first fire to its LAST fire (the real minutes,
# like the hour-range endpoints), a lone hour its own window — so
# "at 00:00-00:50, 08:00-23:50". hasrun() decides; a list without any run
# keeps the classic hourlist() text.
function hasrun(hv,   n,HL,i){ n=split(hv,HL,","); for(i=2;i<=n;i++) if(HL[i]+0==HL[i-1]+1) return 1; return 0 }
function hourruns(hv,mmn,mmx,   n,HL,i,a,b,seg,t){ n=split(hv,HL,","); t=""; i=1
  while(i<=n){ a=HL[i]+0; b=a; while(i<n && HL[i+1]+0==b+1){ i++; b=HL[i]+0 }
    if(b>a) seg=hm(a,mmn) "-" hm(b,mmx); else seg=(mmn==mmx ? hm(a,mmn) : hm(a,mmn) "-" hm(a,mmx))
    t=t (t==""?"":", ") seg; i++ }
  return t }
# smallest (want<0) / largest (want>0) minute a MINUTE field fires at (0..59).
# Parses the RAW field, so a stepped list with an offset (1,16,31,46) keeps its
# true min/max — fieldinfo's "step:N" summary drops the offset. Used for the
# hour-range endpoints so the window ends at the LAST fire, not the whole hour.
function minutemm(fld,want,   parts,np,i,set,k,mn,mx){
  if(fld=="*"||fld=="?") return (want<0 ? 0 : 59)
  split("",set)
  np=split(fld,parts,",")
  for(i=1;i<=np;i++) segset(parts[i],0,59,set)
  mn=-1; mx=0
  for(k=0;k<=59;k++) if(k in set){ if(mn<0) mn=k; mx=k }
  return (want<0 ? (mn<0?0:mn) : mx)
}
# the SECONDS field (Quartz field 1) -> "" when it fires once a minute, else
# "every 30 seconds" | "every second" | "at seconds 0,20,40" (2026-09-28: the
# field was ignored, so "*/30 * * * * ?" read as a once-a-minute schedule)
function secphrase(fld,   s,p){
  s=fieldinfo(fld,60); split(s,p,":")
  if(p[1]=="one"||p[1]=="raw") return ""
  if(p[1]=="all") return "every second"
  if(p[1]=="step") return "every " p[2] " seconds"
  if(p[1]=="range") return "at seconds " p[2] " to " p[3]
  return "at seconds " p[2] }
function cron2human(expr,   f,t,sp,r){
  # a leading blank would make field 1 empty and shift every field (2026-09-28 fix)
  t=expr; sub(/^[ \t]+/,"",t); sub(/[ \t]+$/,"",t)
  if(split(t,f,/[ \t]+/)<6) return expr
  sp=secphrase(f[1]); SECUSED=0
  r=c2h(t,sp); if(r==t) return expr
  if(sp!="" && !SECUSED) r=r ", " sp " within each minute"
  return r }
function c2h(expr,sp,   f,nf,mi,hi,dp,one,dmp,mop,m,mok,mot,mk,mv,hk,hv,ha,hb,p,freq,time,out,mmn,mmx,mst,hst,hstep){
  nf=split(expr,f,/[ \t]+/); if(nf<6||f[2]==""||f[3]=="") return expr
  f[4]=toupper(f[4]); f[5]=toupper(f[5]); f[6]=toupper(f[6])   # Quartz names are case-insensitive
  mi=fieldinfo(f[2],60); hi=fieldinfo(f[3],24); dp=dayphrase(f[6])
  if(mi ~ /^raw:/ || hi ~ /^raw:/) return expr
  # the day-of-month and month fields. ONE day a month (the 1st, the last
  # day, the third Friday, ...) gets its own wording below ("Monthly on the
  # 1st at 08:00"); several days are appended AFTER the time ("Daily at
  # 08:00 on days 1 to 7 for every month")
  one=domone(f[4]); if(one=="" && dp ~ /^on the /){ one=substr(dp,4); dp="" }
  dmp=(one=="" ? domphrase(f[4]) : ""); mop=(one=="" ? monphrase(f[5], dmp!="") : "")
  split(mi,p,":"); mk=p[1]; mv=p[2]; mst=p[3]+0
  split(hi,p,":"); hk=p[1]; hv=p[2]; ha=p[2]; hb=p[3]; hst=p[3]+0
  # a stepped hour window: its own wording beside a single minute, the plain
  # hour list beside a minute step ("every 15 minutes at 08:00, 10:00, …")
  if(hk=="every"){ hstep=p[2]; ha=p[3]; hb=p[4]; if(mk!="one"){ hk="list"; hv=p[5] } }
  mmn=minutemm(f[2],-1); mmx=minutemm(f[2],1)   # actual first/last fire minute, for the hour-range endpoints
  freq=""; time=""
  if(mk=="all" || mk=="step"){
    # every minute (or every Nth): a multi-fire SECONDS field says it
    # itself here — "Every 30 seconds between 08:00 and 17:59"
    if(mk=="all"){ freq=(sp!="" ? toupper(substr(sp,1,1)) substr(sp,2) : "Every minute"); SECUSED=1 }
    else freq="Every " mv " minute" (mv==1?"":"s") ((mst>0 && (hk=="all" || hk=="step")) ? " from :" pad(mst) : "")
    if(hk=="range") time="between " hm(ha,mmn) " and " hm(hb,mmx)
    else if(hk=="one") time="during the " hh(hv) " hour"
    else if(hk=="step") time="in each " hv "-hour window" (hst>0 ? " from " hh(hst) : "")
    else if(hk=="list") time="at " (hasrun(hv) ? hourruns(hv,mmn,mmx) : hourlist(hv))
  } else if(mk=="one" && mv==0){
    if(hk=="all") freq="Every hour"
    else if(hk=="range"){ freq="Hourly"; time="between " hm(ha,mmn) " and " hm(hb,mmx) }
    else if(hk=="one"){ freq="Daily"; time="at " hh(hv) }
    else if(hk=="step") freq="Every " hv " hours" (hst>0 ? " from " hh(hst) : "")
    else if(hk=="every"){ freq="Every " hstep " hours"; time="between " hh(ha) " and " hh(hb) }
    else if(hasrun(hv)){ freq="Hourly"; time="at " hourruns(hv,mmn,mmx) }
    else { freq="Daily"; time="at " hourlist(hv) }
  } else if(mk=="one"){
    if(hk=="all") freq="Every hour at :" pad(mv)
    else if(hk=="one"){ freq="Daily"; time="at " pad(hv) ":" pad(mv) }
    else if(hk=="range"){ freq="Hourly"; time="between " hm(ha,mmn) " and " hm(hb,mmx) }
    else if(hk=="step") freq="Every " hv " hours " (hst>0 ? "from " hm(hst,mv) : "at :" pad(mv))
    else if(hk=="every"){ freq="Every " hstep " hours"; time="between " hm(ha,mv) " and " hm(hb,mv) }
    else if(hasrun(hv)){ freq="Hourly"; time="at " hourruns(hv,mmn,mmx) }
    else { freq="At :" pad(mv); time="at " hourlist(hv) }
  } else {
    freq="At minutes " mv
    if(hk=="range") time="between " hm(ha,mmn) " and " hm(hb,mmx)
    else if(hk!="all") time="at " (hasrun(hv) ? hourruns(hv,mmn,mmx) : hourlist(hv))
  }
  if(one!=""){
    # "Monthly on the 1st at 08:00" | "Yearly on the 1st of December at
    # 08:00" | "At 08:00 on the 1st of January to March" | "Every 15
    # minutes between 08:00 and 17:45 on the 1st of every month"
    m=monset(f[5]); mok=substr(m,1,index(m,":")-1); mot=substr(m,index(m,":")+1)
    if(freq=="Daily" && time!=""){
      if(mok=="all") return "Monthly on " one " " time
      if(mok=="in" && mot !~ /,| to /) return "Yearly on " one " of " mot " " time
      freq="At " substr(time,4); time=""
    }
    out=freq; if(dp!="") out=out " " dp; if(time!="") out=out " " time
    if(mok=="all") return out " on " one " of every month"
    if(mok=="in") return out " on " one " of " mot
    if(mok=="step") return out " on " one ", " mot
    return out " on " one " in month " mot
  }
  if(dp!="" && freq=="Daily" && time!=""){ freq="At " substr(time,4); time="" }  # avoid "Daily ... on workdays"
  out=freq; if(dp!="") out=out " " dp; if(time!="") out=out " " time
  if(dmp!="") out=out " " dmp; if(mop!="") out=out " " mop
  return out
}
BEGIN { FS="\t"; OFS="\t" }
{
  cf = (CF+0 > 0) ? CF+0 : NF
  n=split($cf, L, /\\n/); human=""; disp=""
  for(i=1;i<=n;i++){
    h=cron2human(L[i]); if(i>1) h=tolower(substr(h,1,1)) substr(h,2)
    human=human (human==""?"":"; ") h
    disp=disp (disp==""?"":"\037") L[i]
  }
  $cf = disp
  print $0 "\t" human
}
