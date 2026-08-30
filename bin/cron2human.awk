# cron2human.awk — translate a Quartz 6-field cron expression to plain English.
#
# Shared by bin/analyses/publish.sh (write_cronjobs_page) and
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
function dayphrase(dow,   parts,np,i,seg,a,b,x,set,k,cnt,keys,mn,mx,j,out){
  if(dow=="*"||dow=="?"||dow=="") return ""
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
function cron2human(expr,   f,nf,mi,hi,dp,mk,mv,hk,hv,ha,hb,p,freq,time,out,mmn,mmx){
  nf=split(expr,f,/[ \t]+/); if(nf<6||f[2]==""||f[3]=="") return expr
  mi=fieldinfo(f[2],60); hi=fieldinfo(f[3],24); dp=dayphrase(f[6])
  split(mi,p,":"); mk=p[1]; mv=p[2]
  split(hi,p,":"); hk=p[1]; hv=p[2]; ha=p[2]; hb=p[3]
  mmn=minutemm(f[2],-1); mmx=minutemm(f[2],1)   # actual first/last fire minute, for the hour-range endpoints
  freq=""; time=""
  if(mk=="step"){
    freq="Every " mv " minute" (mv==1?"":"s")
    if(hk=="range") time="between " hm(ha,mmn) " and " hm(hb,mmx)
    else if(hk=="one") time="during the " hh(hv) " hour"
    else if(hk=="step") time="in each " hv "-hour window"
    else if(hk=="list") time="at " hourlist(hv)
  } else if(mk=="one" && mv==0){
    if(hk=="all") freq="Every hour"
    else if(hk=="range"){ freq="Hourly"; time="between " hm(ha,mmn) " and " hm(hb,mmx) }
    else if(hk=="one"){ freq="Daily"; time="at " hh(hv) }
    else if(hk=="step") freq="Every " hv " hours"
    else { freq="Daily"; time="at " hourlist(hv) }
  } else if(mk=="one"){
    if(hk=="all") freq="Every hour at :" pad(mv)
    else if(hk=="one"){ freq="Daily"; time="at " pad(hv) ":" pad(mv) }
    else if(hk=="range"){ freq="Hourly"; time="between " hm(ha,mmn) " and " hm(hb,mmx) }
    else if(hk=="step") freq="Every " hv " hours at :" pad(mv)
    else { freq="At :" pad(mv); time="at " hourlist(hv) }
  } else {
    freq="At minutes " mv
    if(hk=="range") time="between " hm(ha,mmn) " and " hm(hb,mmx)
    else if(hk!="all") time="at " hourlist(hv)
  }
  if(dp!="" && freq=="Daily" && time!=""){ freq="At " substr(time,4); time="" }  # avoid "Daily ... on workdays"
  out=freq; if(dp!="") out=out " " dp; if(time!="") out=out " " time
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
