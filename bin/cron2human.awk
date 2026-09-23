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
    if(seg ~ /-/){ split(seg,a,"-"); b=dnum(a[1]); x=dnum(a[2]); if(b&&x) for(j=b;j<=x;j++) set[j]=1 }
    else { k=dnum(seg); if(k) set[k]=1 } }
  cnt=0; for(k=1;k<=7;k++) if(k in set) keys[++cnt]=k
  if(cnt==0||cnt==7) return ""
  if(cnt==5 && set[1]&&set[2]&&set[3]&&set[4]&&set[5]) return "on workdays"
  if(cnt==2 && set[6]&&set[7]) return "at weekends"
  mn=keys[1]; mx=keys[cnt]
  if(cnt==1) return "on " dname(mn)   # a single day is not a range — "on Monday", never "on Monday to Monday"
  if(mx-mn+1==cnt) return "on " dname(mn) " to " dname(mx)
  out=""; for(i=1;i<=cnt;i++) out=out (out==""?"":", ") dshort(keys[i]); return "on " out
}
# a set of numbers (S[k]=1 over lo..hi) -> "1 to 7, 15, 20 to 25": runs of
# three or more collapse to "A to B", shorter runs stay single values; the
# names table NM (optional) replaces each number by its name
function runtext(S,lo,hi,NM,   k,a,b,t){ t=""; k=lo
  while(k<=hi){ if(!(k in S)){ k++; continue }
    a=k; while((k+1) in S && k+1<=hi) k++; b=k
    if(b-a>=2) t=t (t==""?"":", ") (NM[a]!=""?NM[a]:a) " to " (NM[b]!=""?NM[b]:b)
    else { t=t (t==""?"":", ") (NM[a]!=""?NM[a]:a); if(b>a) t=t ", " (NM[b]!=""?NM[b]:b) }
    k++ }
  return t }
# day-of-month (Quartz field 4) -> "on days 1 to 7" | "on day 15" | "on the
# last day" | "" (every day). Until 2026-09-23 the field was ignored, so
# "0 0 8 1-7 * ?" read as a plain "Daily at 08:00" (Herbert's report).
function domphrase(fld,   a,np,parts,i,seg,b,x,k,S,cnt,NM){
  if(fld=="*"||fld=="?"||fld=="") return ""
  if(fld=="L") return "on the last day"
  if(fld=="LW") return "on the last weekday"
  if(fld ~ /^L-[0-9]+$/) return "on the last day minus " substr(fld,3)+0
  if(fld ~ /^[0-9]+W$/) return "on the weekday nearest day " (substr(fld,1,length(fld)-1)+0)
  if(fld ~ /^([0-9]+|\*)\/[0-9]+$/){ split(fld,a,"/"); return "every " (a[2]+0) " days from day " (a[1]=="*" ? 1 : a[1]+0) }
  if(fld !~ /^[0-9,-]+$/) return "on day-of-month " fld
  np=split(fld,parts,",")
  for(i=1;i<=np;i++){ seg=parts[i]
    if(seg ~ /-/){ split(seg,a,"-"); b=a[1]+0; x=a[2]+0; for(k=b;k<=x;k++) S[k]=1 }
    else S[seg+0]=1 }
  cnt=0; for(k=1;k<=31;k++) if(k in S) cnt++
  if(cnt==0||cnt==31) return ""
  if(cnt==1) for(k=1;k<=31;k++) if(k in S) return "on day " k
  return "on days " runtext(S,1,31,NM)
}
function mnum(s,   M,i){ split("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC",M," ")
  for(i=1;i<=12;i++) if(s==M[i]) return i
  if(s ~ /^[0-9]+$/ && s+0>=1 && s+0<=12) return s+0; return 0 }
# month (Quartz field 5) -> "in January to March" | "in January, July" | ""
# (every month). DOM set -> "for every month" when the month field is open,
# so a day-of-month schedule always says which months it covers.
function monphrase(fld,hasdom,   M,a,np,parts,i,seg,b,x,k,S,cnt){
  split("January February March April May June July August September October November December",M," ")
  if(fld=="*"||fld=="?"||fld=="") return (hasdom ? "for every month" : "")
  if(fld ~ /^([0-9A-Z]+|\*)\/[0-9]+$/){ split(fld,a,"/"); k=(a[1]=="*" ? 1 : mnum(a[1])); if(k) return "every " (a[2]+0) " months from " M[k]; return "in month " fld }
  np=split(fld,parts,",")
  for(i=1;i<=np;i++){ seg=parts[i]
    if(seg ~ /-/){ split(seg,a,"-"); b=mnum(a[1]); x=mnum(a[2]); if(!b||!x) return "in month " fld; for(k=b;k<=x;k++) S[k]=1 }
    else { k=mnum(seg); if(!k) return "in month " fld; S[k]=1 } }
  cnt=0; for(k=1;k<=12;k++) if(k in S) cnt++
  if(cnt==0||cnt==12) return (hasdom ? "for every month" : "")
  return "in " runtext(S,1,12,M)
}
# a numeric cron field -> "all" | "one:V" | "range:A:B" | "step:N" | "list:v,v,.."  (cycle 60|24)
function fieldinfo(fld,cycle,   parts,np,i,seg,a,b,x,set,k,cnt,keys,mn,mx,step,ok,out){
  if(fld=="*"||fld=="?") return "all"
  if(fld ~ /^[0-9]+$/) return "one:" (fld+0)
  if(fld ~ /^([0-9]+|\*)\/[0-9]+$/){ split(fld,a,"/"); return "step:" (a[2]+0) }
  np=split(fld,parts,",")
  for(i=1;i<=np;i++){ seg=parts[i]
    if(seg ~ /-/){ split(seg,a,"-"); b=a[1]+0; x=a[2]+0; for(k=b;k<=x;k++) set[k]=1 }
    else set[seg+0]=1 }
  cnt=0; for(k=0;k<=59;k++) if(k in set) keys[++cnt]=k
  if(cnt==0) return "all"
  if(cnt==1) return "one:" keys[1]
  mn=keys[1]; mx=keys[cnt]
  if(mx-mn+1==cnt) return "range:" mn ":" mx
  step=keys[2]-keys[1]; ok=1; for(i=2;i<=cnt;i++) if(keys[i]-keys[i-1]!=step) ok=0
  if(ok && step>0 && mn<step && mx>=cycle-step) return "step:" step
  out=""; for(i=1;i<=cnt;i++) out=out (out==""?"":",") keys[i]; return "list:" out
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
function minutemm(fld,want,   a,parts,np,i,seg,b,x,set,k,step,st,mn,mx){
  if(fld=="*"||fld=="?") return (want<0 ? 0 : 59)
  if(fld ~ /^[0-9]+$/) return fld+0
  if(fld ~ /^([0-9]+|\*)\/[0-9]+$/){ split(fld,a,"/"); step=a[2]+0; st=(a[1]=="*"?0:a[1]+0)
    if(want<0) return st
    mx=st; while(mx+step<=59) mx+=step; return mx }
  np=split(fld,parts,",")
  for(i=1;i<=np;i++){ seg=parts[i]
    if(seg ~ /-/){ split(seg,a,"-"); b=a[1]+0; x=a[2]+0; for(k=b;k<=x;k++) set[k]=1 }
    else set[seg+0]=1 }
  mn=-1; mx=0
  for(k=0;k<=59;k++) if(k in set){ if(mn<0) mn=k; mx=k }
  return (want<0 ? (mn<0?0:mn) : mx)
}
function cron2human(expr,   f,nf,mi,hi,dp,dmp,mop,mk,mv,hk,hv,ha,hb,p,freq,time,out,mmn,mmx){
  nf=split(expr,f,/[ \t]+/); if(nf<6||f[2]==""||f[3]=="") return expr
  f[4]=toupper(f[4]); f[5]=toupper(f[5]); f[6]=toupper(f[6])   # Quartz names are case-insensitive
  mi=fieldinfo(f[2],60); hi=fieldinfo(f[3],24); dp=dayphrase(f[6])
  # the day-of-month and month fields — appended AFTER the time ("Daily at
  # 08:00 on days 1 to 7 for every month"); an nth/last weekday of the month
  # ("on the third Friday") says its months too
  dmp=domphrase(f[4]); mop=monphrase(f[5], dmp!="" || f[6] ~ /[0-9A-Z]L$|#/)
  split(mi,p,":"); mk=p[1]; mv=p[2]
  split(hi,p,":"); hk=p[1]; hv=p[2]; ha=p[2]; hb=p[3]
  mmn=minutemm(f[2],-1); mmx=minutemm(f[2],1)   # actual first/last fire minute, for the hour-range endpoints
  freq=""; time=""
  if(mk=="step"){
    freq="Every " mv " minute" (mv==1?"":"s")
    if(hk=="range") time="between " hm(ha,mmn) " and " hm(hb,mmx)
    else if(hk=="one") time="during the " hh(hv) " hour"
    else if(hk=="step") time="in each " hv "-hour window"
    else if(hk=="list") time="at " (hasrun(hv) ? hourruns(hv,mmn,mmx) : hourlist(hv))
  } else if(mk=="one" && mv==0){
    if(hk=="all") freq="Every hour"
    else if(hk=="range"){ freq="Hourly"; time="between " hm(ha,mmn) " and " hm(hb,mmx) }
    else if(hk=="one"){ freq="Daily"; time="at " hh(hv) }
    else if(hk=="step") freq="Every " hv " hours"
    else if(hasrun(hv)){ freq="Hourly"; time="at " hourruns(hv,mmn,mmx) }
    else { freq="Daily"; time="at " hourlist(hv) }
  } else if(mk=="one"){
    if(hk=="all") freq="Every hour at :" pad(mv)
    else if(hk=="one"){ freq="Daily"; time="at " pad(hv) ":" pad(mv) }
    else if(hk=="range"){ freq="Hourly"; time="between " hm(ha,mmn) " and " hm(hb,mmx) }
    else if(hk=="step") freq="Every " hv " hours at :" pad(mv)
    else if(hasrun(hv)){ freq="Hourly"; time="at " hourruns(hv,mmn,mmx) }
    else { freq="At :" pad(mv); time="at " hourlist(hv) }
  } else {
    freq="At minutes " mv
    if(hk=="range") time="between " hm(ha,mmn) " and " hm(hb,mmx)
    else if(hk!="all") time="at " (hasrun(hv) ? hourruns(hv,mmn,mmx) : hourlist(hv))
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
