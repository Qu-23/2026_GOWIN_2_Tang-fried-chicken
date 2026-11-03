from pathlib import Path
import hashlib,json,re,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parent
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest=json.loads((ROOT/'SHA256.json').read_text())
for rel,expected in manifest.items():
 assert h(ROOT/rel)==expected,rel
project=ROOT/'fpga/main_Y_HDMI_final.gprj'
entries=list(ET.parse(project).getroot().iter('File'))
for f in entries:assert (project.parent/f.attrib['path']).is_file(),f.attrib['path']
evidence=json.loads((ROOT/'fpga/reports/build_evidence.json').read_text())
edits=json.loads((ROOT/'rtl_comment_edits.json').read_text())
token_re=re.compile(r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/|\\[^\s]+|[A-Za-z_$][\w$]*|\d[\w\']*|[^\s]')
def token_hash(path):
 text=path.read_text(encoding='utf-8-sig')
 tokens=[m.group() for m in token_re.finditer(text) if not m.group().startswith(('//','/*'))]
 return hashlib.sha256(json.dumps(tokens,ensure_ascii=False).encode()).hexdigest()
for rel,edit in edits.items():assert token_hash(ROOT/rel)==edit['token_sha256'],rel
for rel,expected in evidence['inputs'].items():
 target='fpga/'+rel
 if target in edits:assert edits[target]['original_sha256']==expected,target
 else:assert h(ROOT/target)==expected,target
assert h(ROOT/'fpga/main_Y_HDMI_final.fs')==evidence['fs_sha256']
index=json.loads((ROOT/'pc/web/scores/index.json').read_text(encoding='utf-8'))
assert len(index)==6
for entry,waves in zip(index,[[0,3],[0],[3],[3],[0],[0]]):
 score=json.loads((ROOT/'pc/web/scores'/entry['file']).read_text(encoding='utf-8'))
 assert [tr['wave'] for tr in score['tracks']]==waves,entry['name']
print('PASS %d files, %d project entries, built RTL tokens/FS, six-score library'%(len(manifest),len(entries)))
print('CH569 USB input is not implemented; see docs/interface status.')
