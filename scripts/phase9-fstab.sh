#!/usr/bin/env bash
set -uo pipefail
ok(){ echo "  ✅ $*"; }; bad(){ echo "  ❌ $*"; }
sudo -n true 2>/dev/null || { echo "Ejecutá primero: sudo -v"; exit 1; }
BK=~/homelab-backup/fstab.bak-$(date +%s)
sudo cp -a /etc/fstab "$BK" && ok "backup en $BK"
python3 - <<'PY' || { echo "  ❌ falló la generación"; exit 1; }
import re
out=[];n_nofail=0;n_comm=0
for l in open('/etc/fstab').read().splitlines():
    s=l.strip()
    if not s or s.startswith('#'): out.append(l); continue
    f=s.split()
    if len(f)<4: out.append(l); continue
    src,mp,typ,opts=f[0],f[1],f[2],f[3]
    if mp.startswith('/mnt/unified-source'):
        out.append('#lab-disabled# '+l); n_comm+=1; continue
    if typ=='fuse.mergerfs' and src.startswith('/mnt/unified-source'):
        out.append('#lab-disabled# '+l); n_comm+=1; continue
    if mp in ('/mnt/media2','/mnt/media3','/mnt/media4','/mnt/unified-media') and 'nofail' not in opts:
        f[3]=opts+',nofail'; n_nofail+=1; out.append('  '.join(f)); continue
    out.append(l)
open('/tmp/fstab.new','w').write('\n'.join(out)+'\n')
print(f'  comentadas: {n_comm}   con nofail agregado: {n_nofail}')
PY
echo "== Diferencias =="
diff <(sudo cat /etc/fstab) /tmp/fstab.new || true
sudo findmnt --verify --tab-file /tmp/fstab.new 2>&1 | tail -6
read -r -p ">>> Si el diff es correcto escribí SI para instalarlo: " A
if [ "${A:-}" = SI ]; then
  sudo install -m 644 -o root -p /tmp/fstab.new /etc/fstab && sudo systemctl daemon-reload && ok "fstab instalado (rige desde el próximo reinicio)"
else bad "cancelado, /etc/fstab sin cambios"; fi
findmnt /mnt/unified-media -o TARGET,FSTYPE | tail -1
