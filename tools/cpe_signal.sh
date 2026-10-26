#!/system/bin/sh
# Sample NR signal 6 times, 5s apart.
i=0
while [ $i -lt 6 ]; do
  dumpsys telephony.registry 2>/dev/null | grep -oE "ssRsrp = [0-9-]+ ssRsrq = [0-9-]+ ssSinr = [0-9-]+" | head -1
  dumpsys telephony.registry 2>/dev/null | grep -oE "getRilDataRadioTechnology=[0-9]+\([A-Z_]*\)" | head -1
  sleep 5
  i=$((i+1))
done
