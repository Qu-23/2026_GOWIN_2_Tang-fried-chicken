"""Run local source regressions with an installed ModelSim license."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--modelsim',type=Path,required=True);p.add_argument('--license',required=True);a=p.parse_args()
env=dict(os.environ);env.pop('MODELSIM',None);env.pop('LM_LICENSE_FILE',None);env['MGLS_LICENSE_FILE']=a.license
src=ROOT/'fpga/snapshot/src'
core=[f for f in src.rglob('*.v') if '/hdmi/' not in f.as_posix() and '/gowin_' not in f.as_posix() and f.name!='top_main_u.v']
core += [src/'hdmi'/n for n in ['hdmi_pcm.v','hdmi_scope.v','hdmi_status_cdc.v','hdmi_video.v','hdmi_spectrum.sv']]
core += sorted((src/'hdmi/fft').glob('*.v'))+sorted((src/'hdmi/fft').glob('*.sv'))
suites=[('tb_cello_attack40',[src/'realistic/realistic_voice_dsp.v',ROOT/'verification/baseline_dsp.v']),
        ('tb_main_y_cello40',core),('tb_canon_offline',[src/'bt_song.v'])]
for name,sources in suites:
 run=ROOT/'verification/runs'/name;run.mkdir(parents=True,exist_ok=True)
 for item in (ROOT/'fpga').glob('*.hex'):shutil.copyfile(item,run/item.name)
 if name=='tb_canon_offline':
  for filename in ['canon_upload.txt','canon_expected.hex']:shutil.copyfile(ROOT/'verification/canon'/filename,run/filename)
 sources=sources+[ROOT/'verification/sim'/(name+'.v')]
 hashes={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
 (run/'result.log').write_text('RUNNING '+name)
 (run/'run.do').write_text('onerror {quit -code 2 -f}\nrun -all\nquit -f\n')
 commands=[] if (run/'work').exists() else [[str(a.modelsim/'vlib.exe'),'work']]
 commands += [[str(a.modelsim/'vlog.exe'),'-sv','-work','work',*map(str,sources)],
              [str(a.modelsim/'vsim.exe'),'-c','-lib','work','-voptargs=+acc','-do','run.do',name]]
 log=''
 for command in commands:
  try:r=subprocess.run(command,cwd=run,env=env,capture_output=True,text=True,errors='replace',timeout=700)
  except Exception:
   (run/'result.log').write_text(log+'\nFAILED or TIMEOUT\n');raise
  log+=r.stdout+r.stderr;(run/'result.log').write_text(log)
  assert r.returncode==0,log[-6000:]
 assert 'PASS '+name in log and 'FAIL' not in log and '** Error' not in log,log[-6000:]
 for rel,h in hashes.items():assert hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()==h,rel
 (run/'inputs_sha256.json').write_text(json.dumps(hashes,indent=2))
 print('PASS',name)
