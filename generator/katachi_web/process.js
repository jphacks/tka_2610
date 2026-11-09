/* Katachi process viewer (read-only).
   Rebuilds the production steps of a finished run from data the server already exposes:
   project photos / masks / texture regions, final/scene.json, final/editable.glb and the
   silhouette diagnostics. It only issues GET requests and never changes runs or projects.
   The steps are a reconstruction from the recipe, not a recording of the build. */
import {Viewer} from '/viewer.js';

const $=id=>document.getElementById(id);
const el=(tag,cls,text)=>{const e=document.createElement(tag);if(cls)e.className=cls;if(text!==undefined&&text!==null)e.textContent=String(text);return e};
async function getJSON(url){const r=await fetch(url);if(!r.ok)throw Error(`${url} -> HTTP ${r.status}`);return r.json()}
const pad3=n=>String(n).padStart(3,'0');
const fmt=(x,d=3)=>x===null||x===undefined||Number.isNaN(Number(x))?'—':Number(x).toFixed(d);

/* ---------- matrix helpers: same conventions as viewer.js (column-major) ---------- */
const ident=()=>new Float32Array([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]);
const sub=(a,b)=>a.map((x,i)=>x-b[i]);
const dot=(a,b)=>a.reduce((s,x,i)=>s+x*b[i],0);
const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
const unit=a=>{const n=Math.hypot(...a)||1;return a.map(x=>x/n)};
function multiply(a,b){const o=new Float32Array(16);for(let c=0;c<4;c++)for(let r=0;r<4;r++)for(let k=0;k<4;k++)o[c*4+r]+=a[k*4+r]*b[c*4+k];return o}
function lookAt(eye,target){const z=unit(sub(eye,target)),x=unit(cross([0,1,0],z)),y=cross(z,x);return new Float32Array([x[0],y[0],z[0],0,x[1],y[1],z[1],0,x[2],y[2],z[2],0,-dot(x,eye),-dot(y,eye),-dot(z,eye),1])}
function perspective(fov,aspect,near,far){const f=1/Math.tan(fov/2),nf=1/(near-far);return new Float32Array([f/aspect,0,0,0,0,f,0,0,0,0,(far+near)*nf,-1,0,0,2*far*near*nf,0])}
function ortho(size,aspect){const m=ident();m[0]=1/(size*aspect);m[5]=1/size;m[10]=-2/100;m[14]=-1;return m}
function transformNode(n){if(n.matrix)return new Float32Array(n.matrix);const q=n.rotation||[0,0,0,1],s=n.scale||[1,1,1],t=n.translation||[0,0,0],[x,y,z,w]=q;return new Float32Array([(1-2*y*y-2*z*z)*s[0],(2*x*y+2*w*z)*s[0],(2*x*z-2*w*y)*s[0],0,(2*x*y-2*w*z)*s[1],(1-2*x*x-2*z*z)*s[1],(2*y*z+2*w*x)*s[1],0,(2*x*z+2*w*y)*s[2],(2*y*z-2*w*x)*s[2],(1-2*x*x-2*y*y)*s[2],0,...t,1])}
function point(m,x,y,z){return [m[0]*x+m[4]*y+m[8]*z+m[12],m[1]*x+m[5]*y+m[9]*z+m[13],m[2]*x+m[6]*y+m[10]*z+m[14]]}
function apply4(m,[x,y,z]){return [m[0]*x+m[4]*y+m[8]*z+m[12],m[1]*x+m[5]*y+m[9]*z+m[13],m[2]*x+m[6]*y+m[10]*z+m[14],m[3]*x+m[7]*y+m[11]*z+m[15]]}

/* ---------- labels ---------- */
const KIND={loft:'断面をつないだ立体',lathe:'回転体（輪郭を回す）',cylinder:'円柱',gear:'歯車形の輪',rounded_box:'角の丸い箱',box:'箱',extrusion:'板（輪郭を押し出す）',cardboard:'段ボール板',sheet:'薄い板',ellipsoid:'楕円体',superellipsoid:'丸みのある箱',torus:'ドーナツ形',tube:'管',leaf:'葉の形',ribbon:'リボン',bowl:'器',star:'星形',helix:'らせん',contoured_panel:'輪郭パネル',screw:'ねじ',wound_cable:'巻いたケーブル',clay_fusion:'粘土の塊',folded_sheet:'折った紙',sweep_profile:'断面を沿わせた形',contact_bead:'接合の玉縁',layered_panel:'層になった板',surface_patch:'曲面に貼る面'};
const kindLabel=k=>KIND[k]||k;
const STATUS={needs_review:'確認待ち',accepted:'確認済み',failed:'失敗',running:'実行中',queued:'待機中',cancelled:'中止',canceled:'中止'};
const statusLabel=s=>STATUS[s]||String(s||'').replaceAll('_',' ');
const MASK={'manual-mask':'外部で作ったマスクを登録（kt など）','alpha':'画像の透明部分から作成','grabcut-needs-review':'自動の切り抜き（要確認）','rectangle-fallback-needs-review':'範囲指定のみ（要確認）'};
const EVENT={run_started:'実行開始',candidate_built:'候補を生成',candidate_rejected:'候補を却下',candidate_selected:'候補を採用',camera_fit:'カメラ合わせ',local_fit:'数値の局所調整',local_fit_failed:'局所調整に失敗',local_fit_skipped:'局所調整を省略',budget_stop:'予算で停止',run_completed:'実行完了',run_failed:'実行失敗',build:'ビルド',render:'描画',reviewed:'確認済みにした'};
function viewName(yaw){if(yaw===undefined||yaw===null)return '写真';const y=((Math.round(yaw)%360)+540)%360-180;return ({0:'正面',90:'右側面','-90':'左側面','-180':'背面',180:'背面'})[y]??`向き ${y}°`}
function fmtDate(d){if(Number.isNaN(d.getTime()))return '';const p=n=>String(n).padStart(2,'0');return `${d.getMonth()+1}/${d.getDate()} ${p(d.getHours())}:${p(d.getMinutes())}`}

/* ---------- state ---------- */
const S={jobs:[],projects:new Map(),job:null,project:null,scene:null,steps:[],index:0,ticket:0,viewer:null,all:[],prims:[],overlays:new Map(),wire:false,overlayKey:'',playTimer:null};

function message(text){const m=$('pv-message');m.hidden=!text;m.textContent=text||''}

/* ---------- GLB parsing (JSON chunk only; geometry is loaded by Viewer) ---------- */
function parseGLB(buffer){const dv=new DataView(buffer);if(dv.getUint32(0,true)!==0x46546c67)throw Error('Invalid GLB');for(let off=12;off<buffer.byteLength;){const len=dv.getUint32(off,true),type=dv.getUint32(off+4,true);off+=8;if(type===0x4e4f534a)return JSON.parse(new TextDecoder().decode(new Uint8Array(buffer,off,len)));off+=len}throw Error('GLB has no JSON chunk')}
function boxOf(mat,min,max){if(!min||!max)return null;const lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];for(const x of [min[0],max[0]])for(const y of [min[1],max[1]])for(const z of [min[2],max[2]]){const p=point(mat,x,y,z);for(let k=0;k<3;k++){lo[k]=Math.min(lo[k],p[k]);hi[k]=Math.max(hi[k],p[k])}}return {lo,hi}}
// One row per primitive, in exactly the order Viewer.load() pushes its parts.
function primitiveTable(json,scene){
 const ids=scene.parts.filter(p=>!p.construction_only).map(p=>p.id).sort((a,b)=>b.length-a.length);
 const owner=name=>{if(!name)return null;if(ids.includes(name))return name;for(const id of ids){if(name.startsWith(id+':')||(name.startsWith(id+'_')&&/^\d+$/.test(name.slice(id.length+1))))return id}return null};
 const out=[];
 const visit=(nid,parent)=>{const node=json.nodes[nid],mat=multiply(parent,transformNode(node));if(node.mesh!==undefined){const mesh=json.meshes[node.mesh];for(const p of mesh.primitives){if(p.mode!==undefined&&p.mode!==4)continue;const acc=json.accessors[p.attributes.POSITION];out.push({name:node.name||mesh.name||'',part:owner(node.name)??owner(mesh.name),bounds:boxOf(mat,acc.min,acc.max)})}}for(const c of node.children||[])visit(c,mat)};
 const sc=json.scenes[json.scene||0];for(const n of sc.nodes)visit(n,ident());
 return out;
}
function unionBounds(list){const lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];let any=false;for(const b of list){if(!b)continue;any=true;for(let k=0;k<3;k++){lo[k]=Math.min(lo[k],b.lo[k]);hi[k]=Math.max(hi[k],b.hi[k])}}return any?{lo,hi}:null}

/* ---------- section / profile overlays from the recipe ---------- */
function poseFn(t){const r=(t?.rotation_deg||[0,0,0]).map(d=>d*Math.PI/180),s=t?.scale||[1,1,1],pos=t?.translation||[0,0,0];
 const [cx,cy,cz]=r.map(Math.cos),[sx,sy,sz]=r.map(Math.sin);
 const Rx=[[1,0,0],[0,cx,-sx],[0,sx,cx]],Ry=[[cy,0,sy],[0,1,0],[-sy,0,cy]],Rz=[[cz,-sz,0],[sz,cz,0],[0,0,1]];
 const mm=(A,B)=>A.map((row,i)=>[0,1,2].map(j=>row[0]*B[0][j]+row[1]*B[1][j]+row[2]*B[2][j]));
 const R=mm(Rz,mm(Ry,Rx)); // scipy Rotation.from_euler('xyz') (extrinsic), as in geometry.pose_matrix
 return p=>{const q=[p[0]*s[0],p[1]*s[1],p[2]*s[2]];return [0,1,2].map(i=>R[i][0]*q[0]+R[i][1]*q[1]+R[i][2]*q[2]+pos[i])}}
function loftLines(g){const e=g.exponent??1,N=48,rings=[],rails=[[],[],[],[]];
 for(const s of g.sections){const [x,y,z]=s.center,w=s.width,d=s.depth,t=(s.angle_deg||0)*Math.PI/180,ring=[];
  for(let i=0;i<=N;i++){const a=i/N*2*Math.PI,c=Math.cos(a),sn=Math.sin(a),xx=Math.sign(c)*Math.abs(c)**e*w/2,zz=Math.sign(sn)*Math.abs(sn)**e*d/2;ring.push([x+xx*Math.cos(t)+zz*Math.sin(t),y,z-xx*Math.sin(t)+zz*Math.cos(t)])}
  rings.push(ring);for(let k=0;k<4;k++)rails[k].push(ring[k*N/4])}
 return {rings,rails}}
function latheLines(g){const N=48,prof=g.profile,stride=Math.max(1,Math.ceil(prof.length/40)),rings=[],rails=[[],[],[],[]];
 prof.forEach(([r,y],j)=>{if(j%stride===0||j===prof.length-1){if(r>1e-6){const ring=[];for(let i=0;i<=N;i++){const a=i/N*2*Math.PI;ring.push([r*Math.cos(a),y,r*Math.sin(a)])}rings.push(ring)}}for(let k=0;k<4;k++){const a=k*Math.PI/2;rails[k].push([r*Math.cos(a),y,r*Math.sin(a)])}});
 return {rings,rails}}
function buildOverlays(scene,prims){
 const out=new Map();
 for(const part of scene.parts){
  const g=part.geometry||{};if(!['loft','lathe'].includes(g.kind)||part.construction_only||part.repeat||part.attach||(part.modifiers||[]).length)continue;
  const glb=unionBounds(prims.filter(p=>p.part===part.id).map(p=>p.bounds));if(!glb)continue;
  const local=g.kind==='loft'?loftLines(g):latheLines(g),pose=poseFn(part.transform);
  const rings=local.rings.map(r=>r.map(pose)),rails=local.rails.map(r=>r.map(pose));
  const pts=[...rings.flat(),...rails.flat()],lo=[0,1,2].map(k=>Math.min(...pts.map(p=>p[k]))),hi=[0,1,2].map(k=>Math.max(...pts.map(p=>p[k])));
  // Katachi scales the whole recipe uniformly to height_m; recover that scale from this part's GLB bounds.
  const ext=[0,1,2].map(k=>hi[k]-lo[k]),gext=[0,1,2].map(k=>glb.hi[k]-glb.lo[k]);
  const axes=[0,1,2].filter(k=>ext[k]>1e-6).sort((a,b)=>ext[b]-ext[a]);if(!axes.length)continue;
  const s=gext[axes[0]]/ext[axes[0]];
  if(axes.some(k=>Math.abs(gext[k]/ext[k]/s-1)>.15)){console.warn('[process] section overlay skipped (bounds mismatch)',part.id);continue}
  const off=[0,1,2].map(k=>(glb.lo[k]+glb.hi[k])/2-(lo[k]+hi[k])/2*s),map=p=>p.map((v,k)=>v*s+off[k]);
  out.set(part.id,{kind:g.kind,rings:rings.map(r=>r.map(map)),rails:rails.map(r=>r.map(map)),cmPerUnit:s*100,
   summary:g.kind==='loft'?`断面 ${g.sections.length} 個`:`輪郭 ${g.profile.length} 点`});
 }
 return out;
}

/* ---------- small DOM builders ---------- */
const para=t=>el('p',null,t);
const hint=t=>el('p','hint',t);
function table(head,rows){const t=el('table','pv-table'),tr=el('tr');head.forEach(h=>tr.append(el('th',null,h)));t.append(tr);for(const row of rows){const r=el('tr');for(const c of row){const td=el('td');if(c instanceof Node)td.append(c);else if(typeof c==='object'&&c&&'num' in c){td.className='num';td.textContent=c.num}else td.textContent=c??'—';r.append(td)}t.append(r)}return t}
function figure(src,caption,small){const f=el('figure','pv-figure'),img=el('img');img.loading='lazy';img.alt=caption;img.src=src;img.onerror=()=>{img.replaceWith(el('div','pv-empty','画像を読み込めませんでした'))};const cap=el('figcaption',null,caption);if(small)cap.append(el('small',null,small));f.append(img,cap);return f}
function regionFigure(sourceURL,textureURL,region,im){
 const f=el('figure','pv-figure'),row=el('div','pv-pair'),canvas=el('canvas'),tex=el('img');tex.alt=region.label||'取り出した模様';tex.src=textureURL;tex.loading='lazy';
 const img=new Image();img.onload=()=>{const W=img.naturalWidth,H=img.naturalHeight,scale=Math.min(1,900/W);canvas.width=Math.round(W*scale);canvas.height=Math.round(H*scale);const ctx=canvas.getContext('2d');ctx.drawImage(img,0,0,canvas.width,canvas.height);
  const q=(region.quad||[]).map(([x,y])=>[x*canvas.width,y*canvas.height]);if(q.length===4){ctx.fillStyle='rgba(189,146,97,.18)';ctx.strokeStyle='#bd9261';ctx.lineWidth=Math.max(2,canvas.width/220);ctx.beginPath();q.forEach((p,i)=>i?ctx.lineTo(...p):ctx.moveTo(...p));ctx.closePath();ctx.fill();ctx.stroke();
   const r=Math.max(9,canvas.width/45);ctx.font=`bold ${Math.round(r*1.1)}px sans-serif`;ctx.textAlign='center';ctx.textBaseline='middle';q.forEach((p,i)=>{ctx.fillStyle='#bd9261';ctx.beginPath();ctx.arc(...p,r,0,Math.PI*2);ctx.fill();ctx.fillStyle='#fff';ctx.fillText(String(i+1),...p)})}};
 img.onerror=()=>canvas.replaceWith(el('div','pv-empty','元の写真を読み込めませんでした'));img.src=sourceURL;
 row.append(canvas,el('span','arrow','→'),tex);
 const cap=el('figcaption',null,region.label||region.id);cap.append(el('small',null,`${viewName(im.yaw_deg)}の写真から ${region.output_size?.join('×')||''}px で取り出し（1→4 = 左上・右上・右下・左下）`));
 f.append(row,cap);return f}

/* ---------- steps ---------- */
function buildSteps(job,project,scene,jid){
 const steps=[],pid=project?.id,result=job.result||{},views=result.metrics?.views||[];
 const viewIds=views.map(v=>v.image_id);
 const images=(project?.images||[]).filter(im=>!viewIds.length||viewIds.includes(im.id));
 const imageById=id=>(project?.images||[]).find(im=>im.id===id);
 const missing=viewIds.filter(id=>!imageById(id));
 const imgURL=(im,kind)=>`/api/projects/${pid}/images/${im.id}/${kind}`;
 const missingNote=()=>missing.length?[el('p','notice',`この実行で使われた写真のうち ${missing.length} 枚はワークスペースから削除されているため表示できません。`)]:[];

 if(images.length){
  steps.push({group:'写真',type:'gallery',title:'写真を読み込む',sub:`${images.length} 枚`,
   render:()=>images.map(im=>figure(imgURL(im,'source'),viewName(im.yaw_deg),`${im.width}×${im.height}px`)),
   detail:()=>[para('この作品のために登録された写真です。向き（正面・側面・背面）は、最後に 3D モデルと写真を同じ向きで比べるときに使われます。'),
    table(['写真','向き','サイズ'],images.map((im,i)=>[`#${i+1}`,viewName(im.yaw_deg),{num:`${im.width}×${im.height}`}])),...missingNote(),
    hint('表示しているのはワークスペースに今ある写真です。実行後に切り抜きを直した場合は、実行時と少し違うことがあります。')]});
  steps.push({group:'写真',type:'gallery',title:'切り抜き（前景マスク）',sub:'背景を除いて輪郭を取る',
   render:()=>images.map(im=>figure(imgURL(im,'overlay'),viewName(im.yaw_deg),MASK[im.mask_method]||im.mask_method)),
   detail:()=>[para('赤く暗くなっている部分が、背景として除外された領域です。残った部分の輪郭が、形を測る材料になり、最後に 3D モデルと比べる基準にもなります。'),
    table(['写真','切り抜き方法','確認'],images.map(im=>[viewName(im.yaw_deg),MASK[im.mask_method]||im.mask_method,im.mask_reviewed?'済み':'未確認'])),...missingNote()]});
 }else steps.push({group:'写真',type:'gallery',title:'写真',sub:'表示できる写真がありません',render:()=>[el('div','pv-empty','この実行に対応する写真がワークスペースに見つかりませんでした。')],detail:()=>[...missingNote()]});

 const regions=images.flatMap(im=>(im.texture_regions||[]).map(r=>({im,r})));
 if(regions.length)steps.push({group:'模様',type:'gallery',pairs:true,title:'模様を取り出す',sub:`${regions.length} 面`,
  render:()=>regions.map(({im,r})=>regionFigure(imgURL(im,'source'),`/api/projects/${pid}/images/${im.id}/texture-regions/${r.id}/png`,r,im)),
  detail:()=>[para('写真の中の平らな面を四隅で指定し、遠近のゆがみを補正して1枚の画像として取り出します。絵や文字は描き直さず、写真の画素をそのまま使います。'),
   table(['面','元の写真','出力'],regions.map(({im,r})=>[r.label||r.id,viewName(im.yaw_deg),{num:(r.output_size||[]).join('×')}]))]});

 const ringIds=[...S.overlays.keys()];
 if(ringIds.length)steps.push({group:'形',type:'3d',title:'断面・輪郭を決める',sub:ringIds.map(id=>`${id}: ${S.overlays.get(id).summary}`).join(' / '),
  show:new Set(),mode:'clay',rings:ringIds,ringAlpha:.95,highlight:[],detail:()=>sectionDetail(scene,ringIds)});

 // Assembly: parts appear in recipe order. Large recipes are grouped so the list stays readable.
 const order=scene.parts.filter(p=>!p.construction_only).map(p=>({part:p,prims:S.prims.map((x,i)=>x.part===p.id?i:-1).filter(i=>i>=0)})).filter(x=>x.prims.length);
 const orphan=S.prims.map((x,i)=>x.part?-1:i).filter(i=>i>=0);
 const size=order.length<=14?1:Math.ceil(order.length/12),chunks=[];for(let i=0;i<order.length;i+=size)chunks.push(order.slice(i,i+size));
 if(orphan.length&&chunks.length)chunks[chunks.length-1].push({part:{id:'(名前の対応しない部品)',geometry:{kind:'—'},material:'—'},prims:orphan});
 const shown=new Set();
 chunks.forEach((chunk,ci)=>{
  const added=chunk.flatMap(x=>x.prims);added.forEach(i=>shown.add(i));
  const first=chunk[0].part,title=chunk.length===1?first.id:`${first.id} ほか ${chunk.length-1} 部品`;
  const rings=chunk.map(x=>x.part.id).filter(id=>S.overlays.has(id));
  steps.push({group:'組み立て',type:'3d',title,sub:chunk.length===1?`${kindLabel(first.geometry?.kind)} · 材質 ${first.material}`:`${chunk.length} 部品を追加`,
   show:new Set(shown),mode:'clay',rings,ringAlpha:.35,highlight:added,
   detail:()=>assemblyDetail(chunk,ci,chunks.length,scene)});
 });

 if(S.prims.length)steps.push({group:'仕上げ',type:'3d',title:'色・模様を付ける',sub:'材質と取り出した模様を表示',show:new Set(S.prims.map((_,i)=>i)),mode:'photo',rings:[],highlight:[],
  detail:()=>materialDetail(scene,regions,pid)});

 if(views.length){
  const it=pad3(result.selected_iteration??0);
  steps.push({group:'確認',type:'gallery',title:'写真と輪郭を比べる',sub:`2D 一致スコア ${fmt(result.metrics?.score)}`,
   render:()=>views.map(v=>figure(`/api/jobs/${jid}/artifacts/iterations/${it}/diagnostics/${v.image_id}_overlay.png`,imageById(v.image_id)?viewName(imageById(v.image_id).yaw_deg):v.image_id,`IoU ${fmt(v.iou)}`)),
   detail:()=>compareDetail(result,imageById)});
 }
 return steps;
}

function sectionDetail(scene,ids){
 const out=[para('本体の形を決める断面（または回転させる輪郭）です。写真の切り抜きから幅と奥行きを測り、その数値で断面を並べています。このあと、断面のあいだを滑らかにつないで面を張ります。')];
 for(const id of ids){const part=scene.parts.find(p=>p.id===id),g=part.geometry,o=S.overlays.get(id),c=v=>(v*o.cmPerUnit).toFixed(1);
  out.push(el('h3',null,`${id}（${kindLabel(g.kind)}）`));
  if(g.kind==='loft')out.push(table(['#','高さ cm','幅 cm','奥行き cm'],g.sections.map((s,i)=>[String(i+1),{num:c(s.center[1])},{num:c(s.width)},{num:c(s.depth)}])),hint(`断面の形の丸み（exponent）: ${g.exponent??1}。1 で楕円、小さいほど角ばった形になります。`));
  else out.push(table(['#','半径 cm','高さ cm'],g.profile.map(([r,y],i)=>[String(i+1),{num:c(r)},{num:c(y)}])));
 }
 out.push(hint('cm は、モデル全体を指定した高さに合わせたあとの実寸です。'));
 return out;
}
function partRow(p){const name=el('span',null,p.id);if(p.inferred)name.append(el('span','pv-tag','推定'));return [name,kindLabel(p.geometry?.kind),p.material,{num:p.confidence!==undefined?fmt(p.confidence,2):'—'}]}
function assemblyDetail(chunk,ci,total,scene){
 const out=[para(`部品を ${ci+1} / ${total} 段目まで組み立てた状態です。金色の点線の枠が、この段で追加した部品です。`),
  table(['部品','形','材質','確度'],chunk.map(x=>partRow(x.part)))];
 if(chunk.some(x=>x.part.inferred))out.push(hint('「推定」は写真から直接は見えないため、仮定で作った部品です。'));
 const g=chunk.length===1?chunk[0].part.geometry:null;
 if(g){const keys=Object.entries(g).filter(([k,v])=>k!=='kind'&&(typeof v==='number'||(Array.isArray(v)&&v.length>0&&v.length<=4&&v.every(n=>typeof n==='number'))));
  if(keys.length)out.push(el('h3',null,'形の数値（レシピ）'),table(['項目','値'],keys.map(([k,v])=>[k,{num:Array.isArray(v)?v.map(n=>fmt(n,3)).join(', '):fmt(v,4)}])));
  const t=chunk[0].part.transform;if(t)out.push(table(['配置','値'],[['位置',{num:(t.translation||[]).map(n=>fmt(n,2)).join(', ')}],['回転°',{num:(t.rotation_deg||[]).map(n=>fmt(n,0)).join(', ')}]]));}
 if(ci===total-1&&scene.assumptions?.length){out.push(el('h3',null,'レシピに書かれた仮定'));const ul=el('ul');scene.assumptions.forEach(a=>ul.append(el('li',null,a)));ul.style.cssText='font-size:11px;padding-left:18px;margin:0';out.push(ul)}
 return out;
}
function materialDetail(scene,regions,pid){
 const regionById=new Map(regions.map(({im,r})=>[r.id,{im,r}]));
 const rows=(scene.materials||[]).map(m=>{const sw=el('span');const sw2=el('span','pv-swatch');const c=(m.color||[1,1,1,1]).map(v=>Math.round(Math.min(1,Math.max(0,v))*255));sw2.style.background=`rgb(${c[0]},${c[1]},${c[2]})`;sw.append(sw2,document.createTextNode(m.id));
  let tex='—';if(m.image_id){const hit=regionById.get(m.image_id);if(hit){tex=el('img','pv-thumb');tex.src=`/api/projects/${pid}/images/${hit.im.id}/texture-regions/${m.image_id}/png`;tex.alt=hit.r.label||m.image_id}else tex=m.image_id}else if(m.pattern&&m.pattern!=='none')tex=`模様: ${m.pattern}`;
  return [sw,tex,{num:fmt(m.roughness,2)}]});
 return [para('部品ごとの色・質感と、写真から取り出した模様を貼った完成状態です。ここまでの工程はすべて、同じ1つのレシピから決まります。'),table(['材質','模様','粗さ'],rows),
  hint('3D 表示は簡易プレビューです。光の屈折などは再現しません。')];
}
function compareDetail(result,imageById){
 const legend=el('div','pv-legend');for(const [color,text] of [['rgb(225,231,222)','一致している部分'],['rgb(237,115,104)','写真にだけある（モデルが足りない）'],['rgb(87,163,226)','モデルにだけある（はみ出している）']]){const s=el('span'),sw=el('span','pv-swatch');sw.style.background=color;s.append(sw,document.createTextNode(text));legend.append(s)}
 const views=result.metrics?.views||[];
 return [para('完成モデルを写真と同じ向きから描き、切り抜いた輪郭と重ねた結果です。'),legend,
  table(['写真','IoU','境界のずれ'],views.map(v=>[imageById(v.image_id)?viewName(imageById(v.image_id).yaw_deg):v.image_id,{num:fmt(v.iou)},{num:fmt(v.boundary_distance_normalized,4)}])),
  table(['項目','値'],[['総合スコア',{num:fmt(result.metrics?.score)}],['最も低い IoU',{num:fmt(result.metrics?.worst_iou)}],['採用した候補',{num:pad3(result.selected_iteration??0)}],['停止理由',result.stop_reason||'—']]),
  hint('これは 2D の輪郭の一致度で、3D の正確さではありません。見えない面の奥行きは、この数値では確かめられません。')];
}

/* ---------- rendering ---------- */
function renderStepList(){
 const list=$('pv-step-list');list.replaceChildren();let group=null;
 S.steps.forEach((s,i)=>{if(s.group!==group){group=s.group;list.append(el('li','pv-group',group))}const li=el('li'),b=el('button');b.type='button';b.append(el('span','num',i+1),el('strong',null,s.title),el('small',null,s.sub||''));b.onclick=()=>{stopPlay();go(i)};b.dataset.index=i;li.append(b);list.append(li)});
 const slider=$('pv-slider');slider.max=Math.max(0,S.steps.length-1);
}
function go(i){
 if(!S.steps.length)return;
 S.index=Math.max(0,Math.min(S.steps.length-1,i));const step=S.steps[S.index];
 document.querySelectorAll('#pv-step-list button').forEach(b=>{const k=Number(b.dataset.index);b.classList.toggle('active',k===S.index);b.classList.toggle('done',k<S.index);if(k===S.index)b.scrollIntoView({block:'nearest'})});
 $('pv-step-title').textContent=step.title;$('pv-step-group').textContent=step.group;$('pv-step-sub').textContent=step.sub||'';
 $('pv-slider').value=S.index;$('pv-count').textContent=`${S.index+1} / ${S.steps.length}`;
 $('pv-prev').disabled=S.index===0;$('pv-next').disabled=S.index===S.steps.length-1;
 const stage=document.querySelector('.pv-stage'),gallery=$('pv-gallery');
 if(step.type==='gallery'){stage.classList.add('is-gallery');gallery.hidden=false;gallery.className='pv-gallery'+(step.pairs?' pairs':'');gallery.replaceChildren(...step.render());$('pv-3d-controls').hidden=true;message('')}
 else{stage.classList.remove('is-gallery');gallery.hidden=true;gallery.replaceChildren();$('pv-3d-controls').hidden=false;
  if(!S.viewer||!S.all.length)message('3D モデルを読み込めませんでした');
  else{message(step.show.size||step.rings.length?'':'表示する部品がありません');S.viewer.parts=S.all.filter((_,k)=>step.show.has(k));S.viewer.mode=S.wire?'wire':step.mode;S.viewer.dirty=true}}
 $('pv-detail').replaceChildren(...step.detail());
 S.overlayKey='';
}
function overlayLoop(){
 requestAnimationFrame(overlayLoop);const v=S.viewer,c=$('pv-overlay');if(!v)return;
 const key=[v.yaw,v.pitch,v.distance,...v.target,v.orthographic,c.clientWidth,c.clientHeight,S.index,S.ticket].join('|');
 if(key!==S.overlayKey){S.overlayKey=key;drawOverlay()}
}
function drawOverlay(){
 const c=$('pv-overlay'),dpr=Math.min(devicePixelRatio||1,2),w=c.clientWidth,h=c.clientHeight;
 if(c.width!==Math.round(w*dpr)||c.height!==Math.round(h*dpr)){c.width=Math.round(w*dpr);c.height=Math.round(h*dpr)}
 const ctx=c.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);
 const step=S.steps[S.index],v=S.viewer;if(!step||step.type!=='3d'||!w||!h||!v?.model)return;
 const eye=[v.distance*Math.sin(v.yaw)*Math.cos(v.pitch)+v.target[0],v.distance*Math.sin(v.pitch)+v.target[1],v.distance*Math.cos(v.yaw)*Math.cos(v.pitch)+v.target[2]];
 const proj=v.orthographic?ortho(v.distance*.34,w/h):perspective(Math.PI/4,w/h,.01,100),vp=multiply(proj,lookAt(eye,v.target)),model=v.model;
 const project=p=>{const r=apply4(vp,point(model,...p));if(r[3]<=1e-6)return null;return [(r[0]/r[3]+1)/2*w,(1-r[1]/r[3])/2*h]};
 const line=pts=>{ctx.beginPath();let on=false;for(const p of pts){const s=project(p);if(!s){on=false;continue}if(on)ctx.lineTo(...s);else{ctx.moveTo(...s);on=true}}ctx.stroke()};
 for(const id of step.rings){const o=S.overlays.get(id);if(!o)continue;
  ctx.setLineDash([]);ctx.lineWidth=1.6;ctx.strokeStyle=`rgba(66,106,83,${step.ringAlpha})`;o.rings.forEach(line);
  ctx.setLineDash([4,4]);ctx.lineWidth=1;ctx.strokeStyle=`rgba(189,146,97,${Math.min(1,step.ringAlpha+.1)})`;o.rails.forEach(line)}
 if(step.highlight.length){const groups=new Map();for(const i of step.highlight){const p=S.prims[i];if(!p?.bounds)continue;const key=p.part||p.name;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(p.bounds)}
  ctx.setLineDash([5,4]);ctx.lineWidth=1.5;ctx.strokeStyle='#bd9261';ctx.fillStyle='#7a5a2e';ctx.font='600 11px -apple-system,"Segoe UI","Katachi Noto JP",sans-serif';
  for(const [name,list] of groups){const b=unionBounds(list),{lo,hi}=b,C=[];for(const x of [lo[0],hi[0]])for(const y of [lo[1],hi[1]])for(const z of [lo[2],hi[2]])C.push([x,y,z]);
   for(const [a,bb] of [[0,1],[2,3],[4,5],[6,7],[0,2],[1,3],[4,6],[5,7],[0,4],[1,5],[2,6],[3,7]])line([C[a],C[bb]]);
   const sp=C.map(project).filter(Boolean);if(sp.length&&groups.size<=6){const top=sp.reduce((m,p)=>p[1]<m[1]?p:m);ctx.fillText(name,top[0]+6,Math.max(12,top[1]-6))}}
  ctx.setLineDash([])}
}
function drawEvents(events){
 const box=$('pv-events');box.replaceChildren();if(!events.length){box.append(el('div',null,'記録がありません'));return}
 const t0=Date.parse(events[0].time);
 for(const e of events){const row=el('div'),dt=(Date.parse(e.time)-t0)/1000;const detail=e.message||e.reason||(e.iteration!==undefined?`候補 ${pad3(e.iteration)}`+(e.metrics?.score!=null?` / スコア ${fmt(e.metrics.score)}`:''):'');
  row.append(el('span',null,Number.isFinite(dt)?`+${dt.toFixed(1)}s`:''),el('span',null,(EVENT[e.event]||String(e.event).replaceAll('_',' '))+(detail?` — ${detail}`:'')));box.append(row)}
}

/* ---------- playback & controls ---------- */
function stopPlay(){clearTimeout(S.playTimer);S.playTimer=null;$('pv-play').innerHTML='&#9654; 再生';$('pv-play').classList.remove('active')}
function playTick(){go(S.index+1);if(S.index>=S.steps.length-1){stopPlay();return}S.playTimer=setTimeout(playTick,S.steps[S.index].type==='gallery'?2800:1500)}
function togglePlay(){if(S.playTimer){stopPlay();return}if(!S.steps.length)return;if(S.index>=S.steps.length-1)go(0);$('pv-play').innerHTML='&#10073;&#10073; 停止';$('pv-play').classList.add('active');S.playTimer=setTimeout(playTick,S.steps[S.index].type==='gallery'?2800:1500)}
function bindControls(){
 $('pv-prev').onclick=()=>{stopPlay();go(S.index-1)};$('pv-next').onclick=()=>{stopPlay();go(S.index+1)};$('pv-play').onclick=togglePlay;
 $('pv-slider').oninput=e=>{stopPlay();go(Number(e.target.value))};
 $('pv-wire').onclick=()=>{S.wire=!S.wire;$('pv-wire').classList.toggle('active',S.wire);const s=S.steps[S.index];if(S.viewer&&s?.type==='3d'){S.viewer.mode=S.wire?'wire':s.mode;S.viewer.dirty=true}};
 $('pv-spin').onclick=()=>{if(!S.viewer)return;S.viewer.spin=!S.viewer.spin;$('pv-spin').classList.toggle('active',S.viewer.spin)};
 $('pv-reset').onclick=()=>S.viewer?.reset();
 document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>S.viewer?.preset(b.dataset.view));
 document.addEventListener('keydown',e=>{if(e.target.closest('input,select,textarea'))return;if(e.key==='ArrowRight'){stopPlay();go(S.index+1)}else if(e.key==='ArrowLeft'){stopPlay();go(S.index-1)}else if(e.key===' '){e.preventDefault();togglePlay()}});
}

/* ---------- loading ---------- */
async function openRun(id){
 stopPlay();const ticket=++S.ticket;
 const url=new URL(location.href);url.searchParams.set('job',id);history.replaceState(null,'',url);
 S.steps=[];renderStepList();$('pv-detail').replaceChildren();$('pv-step-title').textContent='読み込み中…';$('pv-run-meta').textContent='';
 document.querySelector('.pv-stage').classList.remove('is-gallery');$('pv-gallery').hidden=true;message('実行結果を読み込み中…');
 const job=await getJSON('/api/jobs/'+id);if(ticket!==S.ticket)return;
 const project=S.projects.get(job.project_id)||await getJSON('/api/projects/'+job.project_id).catch(()=>null);if(ticket!==S.ticket)return;
 S.job=job;S.project=project;drawEvents(job.events||[]);
 if(!job.result){$('pv-step-title').textContent=statusLabel(job.status);message(['running','queued'].includes(job.status)?'まだ実行中です。完了すると工程を表示できます。':'完了した結果がないため、工程を表示できません。');return}
 const base=`/api/jobs/${id}/artifacts`;
 const scene=await getJSON(base+'/final/scene.json');if(ticket!==S.ticket)return;
 S.scene=scene;let prims=[];
 if(S.viewer){try{
  message('3D モデルを読み込み中…');
  // The server CSP (connect-src 'self') forbids blob: URLs, so Viewer loads the artifact URL itself.
  // The second fetch for the glTF JSON is answered from the browser cache (ETag revalidation).
  const glbURL=base+'/final/editable.glb';
  if(S.all.length)S.viewer.parts=S.all; // let Viewer free every buffer of the previous model
  await S.viewer.load(glbURL);if(ticket!==S.ticket)return;
  const res=await fetch(glbURL);if(!res.ok)throw Error('editable.glb -> HTTP '+res.status);
  const json=parseGLB(await res.arrayBuffer());if(ticket!==S.ticket)return;
  S.all=S.viewer.parts.slice();prims=primitiveTable(json,scene);
  if(prims.length!==S.all.length){console.warn('[process] primitive table mismatch',prims.length,S.all.length);prims=[]}
 }catch(e){console.error('[process] model load failed',e);S.all=[];prims=[]}}
 S.prims=prims;S.overlays=buildOverlays(scene,prims);
 S.steps=buildSteps(job,project,scene,id);renderStepList();
 const parts=scene.parts.filter(p=>!p.construction_only).length;
 $('pv-run-meta').textContent=`${statusLabel(job.status)} · 部品 ${parts} · 高さ ${fmt((scene.height_m||0)*100,1)} cm · 候補 ${pad3(job.result.selected_iteration??0)} を採用`;
 go(0);
}
async function init(){
 try{S.viewer=new Viewer($('pv-viewer'));S.viewer.mode='clay'}catch(e){console.error(e);S.viewer=null}
 bindControls();requestAnimationFrame(overlayLoop);
 const [jobs,projects]=await Promise.all([getJSON('/api/jobs'),getJSON('/api/projects')]);
 for(const p of projects)S.projects.set(p.id,p);
 S.jobs=[...jobs].sort((a,b)=>String(b.created_at).localeCompare(String(a.created_at)));
 const sel=$('pv-run');sel.replaceChildren();
 if(!S.jobs.length){sel.append(new Option('実行結果がありません',''));$('pv-step-title').textContent='実行結果がありません';message('スタジオでモデルを作ると、ここに工程が表示されます。');return}
 for(const j of S.jobs){const p=S.projects.get(j.project_id);sel.append(new Option(`${p?.title||'（削除されたワークスペース）'} — ${fmtDate(new Date(j.created_at))} / ${statusLabel(j.status)}`,j.id))}
 const wanted=new URLSearchParams(location.search).get('job'),id=S.jobs.some(j=>j.id===wanted)?wanted:S.jobs[0].id;
 sel.value=id;sel.onchange=()=>openRun(sel.value).catch(fail);
 await openRun(id);
}
function fail(e){console.error('[process]',e);message('読み込みに失敗しました: '+(e?.message||e))}
init().catch(fail);
