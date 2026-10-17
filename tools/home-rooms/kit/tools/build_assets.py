#!/usr/bin/env python3
"""Deterministic, editable museum kit. Metres, Y-up, floor-level pivots.
Run: python tools/build_assets.py. Requires numpy, Pillow and shapely.
All meshes and texture pixels are generated here, without external 3D assets.
"""
from __future__ import annotations
import json, math, struct, hashlib, copy, sys
from dataclasses import dataclass
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter
from shapely.geometry import Polygon
from shapely.ops import triangulate

ROOT=Path(__file__).resolve().parents[1]
TEX=ROOT/'assets/textures'
OUT=ROOT/'assets/modules'
for p in (TEX, OUT, ROOT/'assets/scenes', ROOT/'config'): p.mkdir(parents=True,exist_ok=True)
RNG=np.random.default_rng(1729)

# ----- Original, tileable physical-size PBR materials -----
def noise(n, cells, seed):
    r=np.random.default_rng(seed)
    a=r.random((cells,cells))
    a=np.pad(a,((0,1),(0,1)),mode='wrap')
    return np.asarray(Image.fromarray((a*255).astype('uint8')).resize((n+n//cells,n+n//cells),Image.Resampling.BICUBIC),dtype=float)[:n,:n]/255.

def save_tex(name, rgb, height, rough, metres):
    n=height.shape[0]
    rgb=np.clip(rgb,0,255).astype('uint8')
    Image.fromarray(rgb).save(TEX/f'{name}_base.jpg',quality=93,subsampling=0)
    # OpenGL/glTF tangent-space normal, including wrap at texture boundaries.
    dx=(np.roll(height,-1,1)-np.roll(height,1,1))*.5*n/metres[0]
    dy=(np.roll(height,-1,0)-np.roll(height,1,0))*.5*n/metres[1]
    nn=np.stack([-dx,dy,np.ones_like(dx)],axis=-1)
    nn/=np.linalg.norm(nn,axis=-1,keepdims=True)
    Image.fromarray(np.uint8(np.clip(nn*.5+.5,0,1)*255)).save(TEX/f'{name}_normal.png',optimize=True)
    # R=occlusion (neutral), G=roughness, B=metallic (zero).
    orm=np.zeros((n,n,3),dtype=np.uint8);orm[:,:,0]=255;orm[:,:,1]=np.uint8(np.clip(rough,0,1)*255)
    Image.fromarray(orm).save(TEX/f'{name}_orm.png',optimize=True)
    return {'id':name,'tileMeters':list(metres),'baseColor':f'assets/textures/{name}_base.jpg',
            'normal':f'assets/textures/{name}_normal.png','orm':f'assets/textures/{name}_orm.png'}

def build_textures():
    n=1024;y,x=np.mgrid[0:n,0:n]/n
    fine=noise(n,128,1)-.5;mid=noise(n,24,2)-.5;broad=noise(n,6,3)-.5
    out={}
    grain=(np.sin(2*np.pi*(y*88+1.5*np.sin(x*2*np.pi)+.45*np.sin(x*10*np.pi)))+
           .55*np.sin(2*np.pi*(y*231+.8*np.sin(x*4*np.pi))))/1.55
    grain+=.8*fine+.5*mid
    wood=np.stack([189+11*grain+6*broad,147+10*grain+5*broad,99+8*grain+4*broad],-1)
    out['oak']=save_tex('oak',wood,grain*.00020,.47+mid*.12,(1.,1.))
    # Staggered 2 m planks; board colour variation is intentional and repeatable.
    rows=np.floor(y*8).astype(int); offs=np.array([0,.43,.17,.67,.31,.82,.07,.56])
    xx=(x+offs[rows])%1;distance=np.minimum(xx,1-xx)
    seam=(np.minimum((y*8)%1,1-(y*8)%1)<.013)|(distance<.0018)
    bevel=np.minimum(1,np.minimum(np.minimum((y*8)%1,1-(y*8)%1)/.029,distance/.004))
    variations=np.array([0,6,-5,4,-2,8,-6,2])[rows]
    base=np.stack([192+variations+10*grain,152+variations*.8+9*grain,105+variations*.6+8*grain],-1)
    base*=((.81+.19*bevel)[:,:,None]);base[seam]=[109,79,48]
    out['oak_floor']=save_tex('oak_floor',base,grain*.00013+(bevel-1)*.0013,.48+mid*.10,(2.,2.))
    # Vertical oak lining. The 1 m panel repeats have eight narrow boards.
    vg=grain.T; rowx=np.floor(x*8).astype(int);edge=np.minimum((x*8)%1,1-(x*8)%1)
    pbase=np.stack([185+7*vg+variations.T*.3,142+7*vg+variations.T*.3,94+6*vg+variations.T*.3],-1)
    pbase[edge<.018]=[106,74,44]
    out['oak_wall']=save_tex('oak_wall',pbase,vg*.00015-np.maximum(0,1-edge/.035)*.0015,.53+mid*.10,(1.,1.))
    # Lime plaster, restrained grain at true metre scale.
    base=np.stack([230+mid*3+fine*2,226+mid*3+fine*2,215+mid*3+fine*2],-1)
    out['plaster']=save_tex('plaster',base,(fine*.00012+mid*.00010),.83+fine*.08,(1.,1.))
    # Clay brick with real mortar joints and softly irregular face colour.
    rr=np.floor(y*8).astype(int); bx=(x*4+(rr%2)*.5)%1;by=(y*8)%1
    bid=np.floor(x*4+(rr%2)*.5).astype(int)%4
    v=np.random.default_rng(51).uniform(-10,10,(8,4))[rr,bid]
    ed=np.minimum(np.minimum(bx,1-bx)*.25,np.minimum(by,1-by)*.075)
    mortar=ed<.004; bev=np.clip((ed-.002)/.006,0,1)
    b=np.stack([173+v+mid*13+fine*12,105+v*.75+mid*9+fine*9,75+v*.5+mid*7+fine*7],-1)
    b*=.94+.06*bev[:,:,None];b[mortar]=np.stack([193+fine*6,181+fine*6,162+fine*6],-1)[mortar]
    hh=bev*.003+mid*.0006+fine*.00045;hh[mortar]=fine[mortar]*.00015
    out['brick']=save_tex('brick',b,hh,.84+fine*.10,(1.,.6))
    # Honed limestone with quiet sedimentary variation and 0.5 m joints.
    ex=np.minimum((x*2)%1,1-(x*2)%1);ey=np.minimum((y*2)%1,1-(y*2)%1)
    e=np.minimum(ex,ey);vein=np.sin(2*np.pi*(x*4+y*.7+broad*.4))
    stone=np.stack([212+mid*9+broad*12+vein*1.2,204+mid*8+broad*10+vein,186+mid*7+broad*9+vein],-1)
    stone[e<.007]=[168,160,143]
    h=(fine*.0001+mid*.00018)-np.maximum(0,1-e/.015)*.001
    out['limestone']=save_tex('limestone',stone,h,.67+mid*.12,(1.,1.))
    slab=np.stack([215+mid*9+broad*12+vein*1.2,207+mid*8+broad*10+vein,189+mid*7+broad*9+vein],-1)
    out['travertine']=save_tex('travertine',slab,fine*.0001+mid*.00018,.65+mid*.10,(1.,1.))
    # Woven upholstery for the bench; no painted illumination.
    weave=np.sin(x*2*np.pi*220)*np.sin(y*2*np.pi*220)
    fab=np.stack([124+fine*7+weave*3,137+fine*7+weave*3,109+fine*7+weave*3],-1)
    out['fabric']=save_tex('fabric',fab,weave*.000045,.93+fine*.04,(.5,.5))
    return out

# ----- Mesh primitives with explicit normals, UVs and physical pivots -----
@dataclass
class Mesh:
    p: np.ndarray
    n: np.ndarray
    uv: np.ndarray
    f: np.ndarray
    def transformed(self,m):
        p=self.p@m[:3,:3].T+m[:3,3]
        norm=self.n@np.linalg.inv(m[:3,:3]);lens=np.linalg.norm(norm,axis=1,keepdims=True);norm=np.divide(norm,np.maximum(lens,1e-12));norm[lens[:,0]<1e-12]=[0,0,1]
        return Mesh(p,norm,self.uv.copy(),self.f.copy())

def merge(ms):
    ps=[];ns=[];us=[];fs=[];idx=0
    for a in ms:
        ps.append(a.p);ns.append(a.n);us.append(a.uv);fs.append(a.f+idx);idx+=len(a.p)
    return Mesh(np.concatenate(ps),np.concatenate(ns),np.concatenate(us),np.concatenate(fs))

def matrix(pos=(0,0,0),rot=0,scale=(1,1,1)):
    c,s=math.cos(rot),math.sin(rot);m=np.eye(4)
    m[:3,:3]=np.array([[c,0,s],[0,1,0],[-s,0,c]])@np.diag(scale);m[:3,3]=pos;return m

def bevel_box(size,r=.012,pos=(0,0,0),tile=(1,1),rot=0):
    h=np.array(size,dtype=float)/2;r=min(r,float(min(h))*.90);inner=h-r
    ps=[];ns=[];uv=[];fs=[]
    def patch(points,normals,faces):
        start=len(ps)
        for p,n in zip(points,normals):
            ps.append(p);ns.append(n)
            axis=int(np.argmax(np.abs(n)))
            uv.append([p[0]/tile[0],p[2]/tile[1]] if axis==1 else ([p[0]/tile[0],p[1]/tile[1]] if axis==2 else [p[2]/tile[0],p[1]/tile[1]]))
        for face in faces:
            pp=np.array([points[k] for k in face]);cross=np.cross(pp[1]-pp[0],pp[2]-pp[0])
            if np.linalg.norm(cross)<1e-12:continue
            normal=np.sum([normals[k] for k in face],axis=0)
            face=list(face)
            if np.dot(cross,normal)<0:face.reverse()
            fs.append([start+k for k in face])
    # Six flat faces, then twelve quarter cylinders and eight spherical corners.
    for axis in range(3):
        other=[q for q in range(3) if q!=axis]
        for sign in [-1,1]:
            points=[];normal=np.zeros(3);normal[axis]=sign
            for a,b in [(-1,-1),(1,-1),(1,1),(-1,1)]:
                p=np.zeros(3);p[axis]=sign*h[axis];p[other[0]]=a*inner[other[0]];p[other[1]]=b*inner[other[1]];points.append(p)
            patch(points,[normal]*4,[[0,1,2],[0,2,3]])
    seg=3
    for along in range(3):
        a,b=[k for k in range(3) if k!=along]
        for sa in [-1,1]:
            for sb in [-1,1]:
                points=[];normals=[];faces=[]
                for i in range(seg+1):
                    theta=math.pi/2*i/seg;n=np.zeros(3);n[a]=sa*math.cos(theta);n[b]=sb*math.sin(theta)
                    for end in [-1,1]:
                        p=np.zeros(3);p[a]=sa*inner[a];p[b]=sb*inner[b];p[along]=end*inner[along];points.append(p+n*r);normals.append(n)
                for i in range(seg):
                    k=2*i;faces.extend([[k,k+2,k+1],[k+1,k+2,k+3]])
                patch(points,normals,faces)
    for sx in [-1,1]:
        for sy in [-1,1]:
            for sz in [-1,1]:
                points=[];normals=[];faces=[];sgn=np.array([sx,sy,sz])
                for j in range(seg+1):
                    phi=j/seg*math.pi/2
                    for i in range(seg+1):
                        theta=i/seg*math.pi/2;n=sgn*np.array([math.sin(phi)*math.cos(theta),math.cos(phi),math.sin(phi)*math.sin(theta)])
                        points.append(sgn*inner+n*r);normals.append(n)
                for j in range(seg):
                    for i in range(seg):
                        k=j*(seg+1)+i;faces.extend([[k,k+1,k+seg+2],[k,k+seg+2,k+seg+1]])
                patch(points,normals,faces)
    return Mesh(np.array(ps),np.array(ns),np.array(uv),np.array(fs,dtype=int)).transformed(matrix(pos,rot))

def lathe(profile,segments=64,pos=(0,0,0),tile=(1,1)):
    p=[];n=[];uv=[];f=[]
    profile=np.array(profile,float)
    for j,(r,y) in enumerate(profile):
        if j==0: dr,dy=profile[1]-profile[0]
        elif j==len(profile)-1: dr,dy=profile[-1]-profile[-2]
        else: dr,dy=profile[j+1]-profile[j-1]
        nr,ny=dy,-dr;l=max(1e-8,math.hypot(nr,ny))
        for i in range(segments+1):
            a=2*math.pi*i/segments;p.append([r*math.cos(a),y,r*math.sin(a)])
            n.append([nr/l*math.cos(a),ny/l,nr/l*math.sin(a)])
            uv.append([a*max(r,.1)/tile[0],y/tile[1]])
    for j in range(len(profile)-1):
        for i in range(segments):
            a=j*(segments+1)+i;b=a+segments+1
            f.extend([[a,b,a+1],[a+1,b,b+1]])
    return Mesh(np.array(p),np.array(n),np.array(uv),np.array(f)).transformed(matrix(pos))

def cylinder(r,h,pos=(0,0,0),bevel=.01,segments=48):
    b=min(bevel,h/4,r/4)
    return lathe([(0,0),(r-b,0),(r-b*.29,b*.29),(r,b),(r,h-b),(r-b*.29,h-b*.29),(r-b,h),(0,h)],segments,pos)

def arch_band(ri,ro,spring,depth,bevel=.007,segments=48):
    # Continuous ogee-free solid oak arch, softly rounded at the arrises.
    b=bevel;d=depth/2
    prof=[(ri+b,-d),(ro-b,-d),(ro,-d+b),(ro,d-b),(ro-b,d),(ri+b,d),(ri,d-b),(ri,-d+b)]
    p=[];n=[];uv=[];f=[]
    for j,(r,z) in enumerate(prof):
        prev=np.array(prof[j-1]);nxt=np.array(prof[(j+1)%len(prof)])
        dr,dz=nxt-prev;nr,nz=dz,-dr;l=math.hypot(nr,nz)
        for i in range(segments+1):
            a=math.pi*i/segments;p.append([r*math.cos(a),spring+r*math.sin(a),z])
            n.append([nr/l*math.cos(a),nr/l*math.sin(a),nz/l]);uv.append([r*a,z*2])
    for j in range(len(prof)):
        for i in range(segments):
            a=j*(segments+1)+i;c=((j+1)%len(prof))*(segments+1)+i
            f.extend([[a,a+1,c],[a+1,c+1,c]])
    # Close the two ends (covered by the jambs but geometrically complete).
    for i in [0,segments]:
        ids=[j*(segments+1)+i for j in range(len(prof))]
        for j in range(1,len(ids)-1): f.append([ids[0],ids[j],ids[j+1]] if i==0 else [ids[0],ids[j+1],ids[j]])
    return Mesh(np.array(p),np.array(n),np.array(uv),np.array(f))

def extrude_poly(coords,depth,tile=(1,1)):
    poly=Polygon(coords);assert poly.is_valid
    p=[];n=[];uv=[];f=[]
    def tri(pts,norm):
        start=len(p)
        for v in pts: p.append(v);n.append(norm);uv.append([v[0]/tile[0],v[1]/tile[1]])
        vv=np.array(pts);normal=np.cross(vv[1]-vv[0],vv[2]-vv[0]);ind=[start,start+1,start+2]
        if np.dot(normal,norm)<0:ind=ind[::-1]
        f.append(ind)
    for t in triangulate(poly):
        if not poly.covers(t.representative_point()):continue
        xy=list(t.exterior.coords)[:3]
        for sign in [-1,1]:tri([[a,b,sign*depth/2] for a,b in xy],[0,0,sign])
    points=list(poly.exterior.coords)
    is_ccw=poly.exterior.is_ccw
    for a,b in zip(points[:-1],points[1:]):
        dx,dy=b[0]-a[0],b[1]-a[1];norm=np.array([dy,-dx,0.])*(1 if is_ccw else -1);norm/=np.linalg.norm(norm)
        tri([[a[0],a[1],-depth/2],[b[0],b[1],-depth/2],[b[0],b[1],depth/2]],norm)
        tri([[a[0],a[1],-depth/2],[b[0],b[1],depth/2],[a[0],a[1],depth/2]],norm)
    return Mesh(np.array(p),np.array(n),np.array(uv),np.array(f))

def tube_curve(points,r=.02,sides=12):
    # Rotation-minimising frames avoid seams when the tangent crosses an axis.
    pts=np.array(points,float);closed=np.linalg.norm(pts[0]-pts[-1])<1e-8
    tangents=[]
    for j in range(len(pts)):
        if closed and j in [0,len(pts)-1]:t=pts[1]-pts[-2]
        else:t=pts[min(j+1,len(pts)-1)]-pts[max(0,j-1)]
        tangents.append(t/max(np.linalg.norm(t),1e-10))
    helper=np.eye(3)[np.argmin(np.abs(tangents[0]))]
    u=np.cross(tangents[0],helper);u/=np.linalg.norm(u);frames=[u]
    def rotate(vec,axis,angle):
        return vec*math.cos(angle)+np.cross(axis,vec)*math.sin(angle)+axis*np.dot(axis,vec)*(1-math.cos(angle))
    for j in range(1,len(pts)):
        prev=tangents[j-1];cur=tangents[j];axis=np.cross(prev,cur);ln=np.linalg.norm(axis)
        if ln>1e-10:u=rotate(u,axis/ln,math.atan2(ln,np.dot(prev,cur)))
        u-=cur*np.dot(u,cur);u/=np.linalg.norm(u);frames.append(u.copy())
    if closed:
        delta=math.atan2(np.dot(tangents[0],np.cross(frames[-1],frames[0])),np.dot(frames[-1],frames[0]))
        frames=[rotate(u,t,delta*j/(len(pts)-1)) for j,(u,t) in enumerate(zip(frames,tangents))]
    p=[];n=[];uv=[];f=[]
    for j,(q,t,u) in enumerate(zip(pts,tangents,frames)):
        v=np.cross(t,u)
        for i in range(sides+1):
            a=i/sides*2*math.pi;nn=u*math.cos(a)+v*math.sin(a);p.append(q+nn*r);n.append(nn);uv.append([i/sides,j/(len(pts)-1)])
    for j in range(len(pts)-1):
        for i in range(sides):
            a=j*(sides+1)+i;b=a+sides+1
            for ff in [[a,a+1,b],[a+1,b+1,b]]:
                cross=np.cross(np.array(p[ff[1]])-p[ff[0]],np.array(p[ff[2]])-p[ff[0]])
                if np.dot(cross,np.sum([n[k] for k in ff],axis=0))<0:ff.reverse()
                f.append(ff)
    return Mesh(np.array(p),np.array(n),np.array(uv),np.array(f))

def leaf(length,width,bend=.14):
    p=[];uv=[];f=[]
    for j in range(13):
        t=j/12;w=math.sin(math.pi*t)**.75*width/2
        for k in range(5):
            s=(k/4-.5)*2;p.append([s*w, t*length, bend*t*t+.055*abs(s)*math.sin(math.pi*t)])
            uv.append([k/4,t])
    for j in range(12):
        for k in range(4):a=j*5+k;f.extend([[a,a+1,a+6],[a,a+6,a+5]])
    p=np.array(p);f=np.array(f);norm=np.zeros_like(p)
    for ff in f:
        nn=np.cross(p[ff[1]]-p[ff[0]],p[ff[2]]-p[ff[0]]);norm[ff]+=nn
    norm/=np.maximum(np.linalg.norm(norm,axis=1,keepdims=True),1e-10)
    return Mesh(p,norm,np.array(uv),f)

# glTF assembly uses shared mesh/accessor storage across all repeated instances.
MATERIALS={};ASSETS={}
def mat(name,color,rough=.6,metal=0,texture=None,double=False,alpha=None,emissive=None):
    MATERIALS[name]={'name':name,'color':color,'rough':rough,'metal':metal,'texture':texture,'double':double,'alpha':alpha,'emissive':emissive}

def component(name,mesh,material,role=None):
    return {'name':name,'mesh':mesh,'material':material,'extras':{'role':role} if role else {}}
def asset(aid,parts,size,placement='floor',category='furniture',label=None):
    ASSETS[aid]={'id':aid,'parts':parts,'size':size,'placement':placement,'category':category,'label':label or aid,
                 'extras':{'assetId':aid,'category':category,'placement':placement,'pivot':'bottom-center','dimensionsMeters':size}}

def build_assets():
    mat('Wall_Plaster',[.90,.88,.83,1],texture='plaster')
    mat('Wall_Oak',[1,1,1,1],texture='oak_wall')
    mat('Wall_Brick',[1,1,1,1],texture='brick')
    mat('Wall_Limestone',[1,1,1,1],texture='limestone')
    mat('Floor_Oak',[1,1,1,1],texture='oak_floor')
    mat('Floor_Limestone',[1,1,1,1],texture='limestone')
    mat('Trim_Oak',[1,1,1,1],texture='oak')
    mat('Ceramic_Ivory',[.85,.82,.75,1],.42)
    mat('Stone_Travertine',[1,1,1,1],texture='travertine')
    mat('Metal_Brass',[.53,.34,.12,1],.32,.82)
    mat('Metal_Dark',[.07,.064,.049,1],.36,.65)
    mat('Foundation',[.31,.29,.255,1],.9)
    mat('Shadow_Reveal',[.12,.10,.07,1],.84)
    mat('Linen_Sage',[1,1,1,1],texture='fabric')
    mat('Linen_Ivory',[.84,.81,.74,1],.97)
    mat('Linen_Cream',[.89,.84,.73,1],.88)
    mat('Linen_Rose',[.79,.61,.53,1],.93)
    mat('Sage_Painted_Wood',[.41,.52,.40,1],.68)
    mat('Warm_White_Paint',[.87,.82,.72,1],.78)
    mat('Book_Rose',[.67,.39,.38,1],.83)
    mat('Book_Blue',[.32,.48,.58,1],.83)
    mat('Book_Cream',[.85,.72,.48,1],.86)
    mat('Terracotta',[.24,.10,.045,1],.84)
    mat('Soil',[.07,.045,.025,1],1)
    mat('Leaf_Deep',[.035,.08,.018,1],.65,double=True)
    mat('Leaf_Mid',[.075,.15,.028,1],.60,double=True)
    mat('Leaf_Light',[.12,.22,.05,1],.64,double=True)
    mat('Ceramic_Sage',[.29,.40,.33,1],.32)
    mat('Art_Brass',[.46,.23,.075,1],.23,.83)
    mat('LED_Warm',[1,.88,.67,1],.4,emissive=[1,.73,.38])
    mat('Glass_Clear',[.82,.92,.91,.17],.08,alpha='BLEND',double=True)
    H=3.2
    for w in [1.,.5]:
        parts=[component('Wall_Lower',bevel_box((w,.92,.24),.004,(0,.46,0)), 'Wall_Plaster','wall_lower'),
               component('Wall_Upper',bevel_box((w,H-.92,.24),.004,(0,.92+(H-.92)/2,0)), 'Wall_Plaster','wall_upper')]
        for side in [-1,1]:
            parts += [component(f'Baseboard_{side}',bevel_box((w,.17,.047),.008,(0,.085,side*.134)),'Trim_Oak','trim_lower'),
                      component(f'Basecap_{side}',bevel_box((w,.027,.061),.005,(0,.177,side*.138)),'Trim_Oak','trim_lower'),
                      component(f'Crown_{side}',bevel_box((w,.095,.073),.008,(0,H-.08,side*.14)),'Trim_Oak','trim_upper'),
                      component(f'Cornice_{side}',bevel_box((w,.034,.094),.006,(0,H-.015,side*.143)),'Trim_Oak','trim_upper')]
        asset('wall_1m' if w==1 else 'wall_05m',parts,[w,H,.32],'wall','architecture')
    # Portal fits a 3 m wall bay, and never scales with the room dimensions.
    r=1.05;spring=1.55
    coords=[(-1.5,0),(-1.5,H),(1.5,H),(1.5,0),(r,0),(r,spring)]
    coords += [(r*math.cos(t),spring+r*math.sin(t)) for t in np.linspace(0,math.pi,49)[1:]]
    coords += [(-r,0)]
    parts=[component('Portal_Wall',extrude_poly(coords,.24),'Wall_Plaster','wall')]
    frames=[];base=[];trim=[]
    for side in [-1,1]:
        frames.append(arch_band(r,r+.145,spring,.052).transformed(matrix((0,0,side*.15))))
        # A fine brass reveal makes the architectural join legible without ornament.
        trim.append(arch_band(r+.007,r+.020,spring,.010,.002).transformed(matrix((0,0,side*.181))))
        for x in [-r-.0725,r+.0725]:
            frames.append(bevel_box((.145,spring,.058),.008,(x,spring/2,side*.15)))
            base.append(bevel_box((.19,.20,.076),.007,(x,.10,side*.157)))
        for sign in [-1,1]:
            base.append(bevel_box((.27,.17,.047),.007,(sign*1.365,.085,side*.134)))
        frames.append(bevel_box((3,.095,.073),.008,(0,H-.08,side*.14)))
        frames.append(bevel_box((3,.034,.094),.006,(0,H-.015,side*.143)))
    parts += [component('Oak_Arch_and_Jambs',merge(frames),'Trim_Oak','trim'),component('Oak_Plinth',merge(base),'Trim_Oak','trim'),component('Brass_Inner_Reveal',merge(trim),'Metal_Brass','accent')]
    asset('portal_arch_3m',parts,[3,H,.38],'wall','architecture')
    asset('passage_vault_1m',[component('Vault_Shell',arch_band(r,r+.11,spring,1.,.007),'Wall_Plaster','ceiling')],[2.32,2.71,1.],'ceiling','architecture')
    asset('corner_post',[component('Oak_Column',bevel_box((.14,H,.14),.012,(0,H/2,0)),'Trim_Oak','trim'),
                         component('Foot',bevel_box((.19,.20,.19),.007,(0,.10,0)),'Trim_Oak','trim'),
                         component('Capital',bevel_box((.21,.14,.21),.008,(0,H-.07,0)),'Trim_Oak','trim')],[.21,H,.21],'floor','architecture')
    asset('floor_1m',[component('Slab',bevel_box((1,.18,1),.006,(0,-.10,0)),'Foundation','foundation'),
                      component('Finish',bevel_box((1,.02,1),.002,(0,-.01,0),tile=(2,2)),'Floor_Oak','floor')],[1,.2,1],'floor','architecture')
    asset('ceiling_1m',[component('Ceiling',bevel_box((1,.08,1),.004,(0,.04,0)),'Wall_Plaster','ceiling')],[1,.08,1],'ceiling','architecture')
    # Pedestals: separate objects, feet at Y=0 and named top anchors.
    parts=[component('Body',bevel_box((.82,.94,.82),.035,(0,.56,0)),'Ceramic_Ivory'),
           component('Recessed_Foot',bevel_box((.68,.09,.68),.01,(0,.045,0)),'Shadow_Reveal'),
           component('Brass_Reveal',bevel_box((.78,.016,.78),.006,(0,1.031,0)),'Metal_Brass'),
           component('Top',bevel_box((.87,.065,.87),.019,(0,1.0715,0)),'Ceramic_Ivory')]
    asset('plinth_ivory',parts,[.87,1.104,.87],label='Ivory / square')
    parts=[component('Body',bevel_box((.55,1.14,.55),.024,(0,.63,0)),'Stone_Travertine'),
           component('Recessed_Foot',bevel_box((.47,.06,.47),.008,(0,.03,0)),'Shadow_Reveal'),
           component('Top',bevel_box((.59,.035,.59),.008,(0,1.2175,0)),'Stone_Travertine')]
    asset('plinth_slim',parts,[.59,1.235,.59],label='Travertine / tall')
    flutes=[]
    for i in range(48):
        a=i*2*math.pi/48;flutes.append(cylinder(.025,.90,(.435*math.cos(a),.09,.435*math.sin(a)),.004,12))
    parts=[component('Inner_Drum',cylinder(.434,.90,(0,.09,0),.01),'Trim_Oak'),
           component('Oak_Flutes',merge(flutes),'Trim_Oak'),
           component('Foot',cylinder(.40,.09,(0,0,0),.01),'Shadow_Reveal'),
           component('Brass_Collar',cylinder(.451,.02,(0,.979,0),.005),'Metal_Brass'),
           component('Stone_Cap',cylinder(.49,.07,(0,.999,0),.018,80),'Stone_Travertine')]
    for part in parts:
        if part['material']=='Trim_Oak':part['mesh'].uv=part['mesh'].uv[:,[1,0]].copy()
    asset('plinth_fluted',parts,[.98,1.069,.98],label='Oak / fluted')
    parts=[component('Low_Stone',bevel_box((1.80,.31,1.15),.06,(0,.235,0)),'Stone_Travertine'),
           component('Floating_Base',bevel_box((1.64,.08,.99),.018,(0,.04,0)),'Shadow_Reveal')]
    asset('plinth_low',parts,[1.80,.39,1.15],label='Travertine / low')
    # Bench with inset seat, rounded timber frame and four splayed wooden feet.
    wood=[bevel_box((1.85,.095,.60),.024,(0,.38,0))]
    for x in [-.68,.68]:
        for z in [-.19,.19]:wood.append(bevel_box((.085,.36,.085),.015,(x,.18,z)))
    wood.append(bevel_box((1.40,.055,.055),.012,(0,.16,0)))
    parts=[component('Oak_Frame',merge(wood),'Trim_Oak'),component('Upholstery',bevel_box((1.77,.15,.54),.06,(0,.496,0),tile=(.5,.5)),'Linen_Sage')]
    # Welting is modelled rather than painted onto the cushion.
    pts=[]
    for cx,cz,baseang in [(.817,.207,0),(-.817,.207,90),(-.817,-.207,180),(.817,-.207,270)]:
        for t in np.linspace(math.radians(baseang),math.radians(baseang+90),10):pts.append([cx+.065*math.cos(t),.491,cz+.065*math.sin(t)])
    # Use a rectangular seam inset from the actual outer edge.
    seam=[[-.80,.49,-.23],[.80,.49,-.23],[.85,.49,-.18],[.85,.49,.18],[.80,.49,.23],[-.80,.49,.23],[-.85,.49,.18],[-.85,.49,-.18],[-.80,.49,-.23]]
    parts.append(component('Piping',tube_curve(seam,.004,6),'Linen_Sage'))
    asset('bench_oak',parts,[1.85,.571,.60],label='Oak / upholstered bench')
    # Glass vitrine with a narrow brass frame; avoids mandatory transmission shaders.
    parts=copy.copy(ASSETS['plinth_ivory']['parts'])
    frame=[]
    for x in [-.395,.395]:
        for z in [-.395,.395]:frame.append(bevel_box((.013,.77,.013),.003,(x,1.489,z)))
    for y in [1.115,1.87]:
        for z in [-.395,.395]:frame.append(bevel_box((.80,.013,.013),.003,(0,y,z)))
        for x in [-.395,.395]:frame.append(bevel_box((.013,.013,.80),.003,(x,y,0)))
    glass=[]
    for z in [-.389,.389]:glass.append(bevel_box((.769,.742,.003),.0005,(0,1.489,z)))
    for x in [-.389,.389]:glass.append(bevel_box((.003,.742,.769),.0005,(x,1.489,0)))
    glass.append(bevel_box((.78,.003,.78),.0005,(0,1.868,0)))
    parts += [component('Brass_Case_Frame',merge(frame),'Metal_Brass'),component('Glass_Panes',merge(glass),'Glass_Clear')]
    asset('vitrine',parts,[.87,1.88,.87],label='Ivory / glass vitrine')
    # Gallery frame; front is +Z and the bottom edge is Y=0.
    parts=[component('Linen_Backing',bevel_box((.64,.84,.02),.001,(0,.46,.023)),'Linen_Ivory','art_surface')]
    rails=[bevel_box((.74,.035,.045),.006,(0,y,.03)) for y in [.035,.885]]
    rails += [bevel_box((.035,.815,.045),.006,(x,.46,.03)) for x in [-.3525,.3525]]
    parts.append(component('Oak_Frame',merge(rails),'Trim_Oak'))
    parts.append(component('Museum_Label',bevel_box((.24,.075,.010),.003,(.25,-.09,.021)),'Ceramic_Ivory'))
    asset('wall_frame',parts,[.74,1.00,.056],'wall','wall_decor',label='Oak / picture frame')
    # Picture light with a brass arm, metallic casing, and emissive diffuser.
    parts=[component('Backplate',bevel_box((.11,.15,.025),.018,(0,.075,.015)),'Metal_Brass'),
           component('Arm',bevel_box((.025,.025,.16),.006,(0,.11,.08)),'Metal_Brass'),
           component('Housing',bevel_box((.37,.045,.09),.013,(0,.10,.18)),'Metal_Brass'),
           component('Diffuser',bevel_box((.30,.008,.060),.003,(0,.075,.18)),'LED_Warm','light_emitter')]
    asset('picture_light',parts,[.37,.15,.225],'wall','lighting',label='Brass / picture light')
    # Ceiling downlight.
    parts=[component('Bezel',cylinder(.070,.016,(0,0,0),.004),'Metal_Brass'),
           component('Emitter',cylinder(.052,.017,(0,0,0),.003),'LED_Warm','light_emitter')]
    asset('downlight',parts,[.14,.017,.14],'ceiling','lighting')
    # Potted plant: shaped pot lip, soil and individual gently curved leaves.
    pot=lathe([(0,0),(.18,0),(.195,.015),(.208,.06),(.255,.43),(.258,.47),(.253,.492),(.228,.492),(.221,.466),(.213,.44),(.18,.10),(0,.10)],64)
    parts=[component('Terracotta_Pot',pot,'Terracotta'),component('Soil',cylinder(.215,.016,(0,.442,0),.002),'Soil')]
    leaves=[[],[],[]];stems=[]
    rr=np.random.default_rng(44)
    stems.append(tube_curve([[0,.44,0],[.015,.77,.005],[-.015,1.10,.015],[0,1.42,0]],.012,8))
    for i in range(15):
        ang=i*2.399963;le=.32+rr.random()*.17;w=.22+rr.random()*.12
        tier=i//5;start_y=.60+tier*.25
        tilt=.65+rr.random()*.55
        rx=np.eye(4);c,s=math.cos(tilt),math.sin(tilt);rx[:3,:3]=[[1,0,0],[0,c,-s],[0,s,c]]
        start=(math.sin(ang)*.12,start_y,math.cos(ang)*.12)
        m=matrix(start,ang)@rx
        leaves[i%3].append(leaf(le,w,.09).transformed(m))
        stems.append(tube_curve([[0,start_y-.09,0],start],.005,6))
    for i,arr in enumerate(leaves):parts.append(component(f'Leaves_{i}',merge(arr),['Leaf_Deep','Leaf_Mid','Leaf_Light'][i]))
    parts.append(component('Stems',merge(stems),'Leaf_Deep'))
    asset('plant',parts,[1.0,1.65,1.0],label='Botanical / terracotta')
    # Home Edition: everyday furniture is deliberately separate from architecture.
    # All origins are floor-centred. Pieces are self-contained meshes, no room scaling.
    def boxgroup(name, shapes, material):
        return component(name,merge(shapes),material)

    # Soft two-seat sofa: oak apron and feet, fabric body, separate cushions and piping.
    oak=[]
    for x in [-1.00,1.00]:
        for z in [-.30,.30]:oak.append(bevel_box((.105,.18,.105),.015,(x,.09,z)))
    oak.extend([bevel_box((2.18,.10,.78),.026,(0,.215,0)),bevel_box((2.07,.055,.06),.012,(0,.21,.355))])
    fabric=[bevel_box((2.16,.255,.79),.075,(0,.405,0)),bevel_box((2.13,.59,.205),.085,(0,.68,-.37))]
    fabric.extend(bevel_box((.23,.48,.85),.08,(sg*1.07,.61,0)) for sg in [-1,1])
    cushions=[bevel_box((.975,.155,.67),.068,(x,.562,.055)) for x in [-.53,.53]]
    cushions.extend([bevel_box((.62,.37,.14),.04,(x,.68,-.234)) for x in [-.55,.55]])
    pipings=[]
    for x in [-.53,.53]:
        pipings.append(tube_curve([(x-.47,.628,-.27),(x+.47,.628,-.27)],.004,6))
    asset('home_sofa',[
        boxgroup('Warm_Oak_Base',oak,'Trim_Oak'),
        boxgroup('Soft_Sage_Frame',fabric,'Linen_Sage'),
        boxgroup('Loose_Cream_Cushions',cushions,'Linen_Cream'),
        boxgroup('Small_Piping_Details',pipings,'Linen_Ivory')],
        [2.36, .985, .90],label='Sage / two-seat sofa')

    # Rounded coffee table; two-tone top, jointed legs and lower stretcher.
    legs=[bevel_box((.085,.41,.085),.014,(x,.205,z)) for x in [-.51,.51] for z in [-.255,.255]]
    rails=[bevel_box((1.07,.055,.065),.008,(0,.135,z)) for z in [-.255,.255]]
    asset('home_coffee_table',[
        boxgroup('Solid_Oak_Legs',legs+rails,'Trim_Oak'),
        component('Rounded_Top',bevel_box((1.37,.08,.78),.045,(0,.475,0)),'Trim_Oak'),
        component('Cream_Inset',bevel_box((1.14,.009,.57),.004,(0,.520,0)),'Linen_Cream')],
        [1.37,.525,.78],label='Oak / coffee table')

    # A low credenza: movable display surface for crafts, with two independent doors.
    cabinet=[bevel_box((1.70,.67,.46),.032,(0,.48,0)),bevel_box((1.77,.072,.51),.025,(0,.855,0))]
    legs=[bevel_box((.085,.17,.075),.012,(x,.085,z)) for x in [-.70,.70] for z in [-.17,.17]]
    door=[bevel_box((.77,.52,.025),.012,(x,.49,.247)) for x in [-.405,.405]]
    handles=[bevel_box((.055,.12,.029),.010,(x,.53,.272)) for x in [-.08,.08]]
    asset('home_console',[
        boxgroup('Oak_Carcass',cabinet+legs,'Trim_Oak'),
        boxgroup('Sage_Door_Panels',door,'Sage_Painted_Wood'),
        boxgroup('Brass_Handles',handles,'Metal_Brass')],
        [1.77,.891,.51],label='Sage / low sideboard')

    # Tall open shelf, restrained profile with intentional little hand-positioned books.
    wood=[bevel_box((1.16,.065,.39),.01,(0,.055,0))]
    for x in [-.55,.55]:wood.append(bevel_box((.058,1.72,.39),.011,(x,.91,0)))
    for y in [.17,.58,.99,1.40,1.77]:wood.append(bevel_box((1.13,.05,.39),.014,(0,y,0)))
    wood.append(bevel_box((1.10,1.57,.026),.005,(0,.98,-.188)))
    books=[[],[],[]]
    rr=np.random.default_rng(88)
    for j,(level,count) in enumerate([(.20,7),(.61,4),(1.02,6),(1.43,5)]):
        xx=-.42
        for i in range(count):
            width=.065+rr.random()*.06
            height=.20+rr.random()*.12
            books[(j+i)%3].append(bevel_box((width,height,.20),.006,(xx+width/2,level+.026+height/2,.012)))
            xx+=width+.025
    asset('home_bookshelf',[
        boxgroup('Oak_Shelving',wood,'Trim_Oak'),
        boxgroup('Book_Covers_Terracotta',books[0],'Book_Rose'),
        boxgroup('Book_Covers_Coastal',books[1],'Book_Blue'),
        boxgroup('Book_Covers_Cream',books[2],'Book_Cream')],
        [1.16,1.82,.41],label='Oak / book shelf')

    # Simple craft desk with raised back lip, inset writing top and a single drawer.
    legs=[bevel_box((.075,.70,.075),.012,(x,.35,z)) for x in [-.68,.68] for z in [-.31,.31]]
    aprons=[bevel_box((1.38,.115,.042),.008,(0,.63,z)) for z in [-.31,.31]]
    drawer=[bevel_box((.45,.145,.02),.007,(.35,.617,.345))]
    asset('home_craft_desk',[
        boxgroup('Oak_Desk_Legs_And_Apron',legs+aprons,'Trim_Oak'),
        component('Rounded_Writing_Surface',bevel_box((1.54,.082,.74),.026,(0,.745,0)),'Trim_Oak'),
        component('Pale_Work_Area',bevel_box((1.27,.009,.57),.004,(0,.791,0)),'Linen_Cream'),
        component('Desk_Drawer',drawer[0],'Warm_White_Paint'),
        component('Brass_Handle',bevel_box((.14,.024,.024),.005,(.35,.62,.367)),'Metal_Brass')],
        [1.54,.795,.74],label='Oak / craft desk')

    # A sturdy stool with a gentle sculptural taper and foot rail.
    legs=[bevel_box((.072,.40,.072),.012,(x,.20,z)) for x in [-.20,.20] for z in [-.20,.20]]
    support=[bevel_box((.40,.04,.042),.006,(0,.19,z)) for z in [-.20,.20]]
    asset('home_stool',[
        boxgroup('Oak_Legs',legs+support,'Trim_Oak'),
        component('Soft_Seat',bevel_box((.52,.11,.52),.052,(0,.465,0)),'Linen_Sage')],
        [.52,.52,.52],label='Sage / footstool')

    # Everyday low open shelf, explicitly kept usable as a display support.
    shelves=[bevel_box((1.40,.065,.45),.018,(0,y,0)) for y in [.11,.44,.81]]
    shelves.extend([bevel_box((.055,.82,.45),.010,(x,.41,0)) for x in [-.67,.67]])
    for x in [-.60,.60]:shelves.append(bevel_box((.09,.06,.38),.010,(x,.03,0)))
    asset('home_display_shelf',[
        boxgroup('Three_Oak_Shelves',shelves,'Trim_Oak'),
        component('Sage_Back_Panel',bevel_box((1.23,.63,.022),.005,(0,.48,-.215)),'Sage_Painted_Wood')],
        [1.40,.843,.45],label='Oak / open display shelf')

    # Fabric area rug can layer below furniture. Placeability excludes it from hard collisions.
    rug1=cylinder(1,.018,(0,0,0),.006,84).transformed(matrix(scale=(1.5,1,1.13)))
    rug2=cylinder(.92,.006,(0,.017,0),.003,84).transformed(matrix(scale=(1.5,1,1.13)))
    asset('home_rug',[
        component('Woven_Rose_Border',rug1,'Linen_Rose'),
        component('Ivory_Fabric_Centre',rug2,'Linen_Cream')],
        [3,.023,2.26],label='Cream / woven rug')

    # Floor lamp. Cylindrical shade with inner diffuser, cord and small brass rim.
    stand=[cylinder(.19,.04,(0,0,0),.01,64),cylinder(.022,1.41,(0,.045,0),.006,32)]
    shade=lathe([(.23,1.30),(.27,1.31),(.36,1.54),(.355,1.60),(.31,1.62),(.21,1.55)],48)
    cap=cylinder(.25,.024,(0,1.59,0),.004,48)
    asset('home_floor_lamp',[
        boxgroup('Brass_Stem',stand,'Metal_Brass'),
        component('Woven_Cream_Lampshade',shade,'Linen_Cream'),
        component('Warm_Diffuser',cap,'LED_Warm')],
        [.72,1.62,.72],label='Cream / floor lamp')

    # Original, removable exhibition samples.
    vase=lathe([(0,0),(.12,0),(.15,.035),(.19,.13),(.20,.23),(.18,.33),(.10,.43),(.073,.49),(.073,.57),(.069,.586),(.052,.586),(.050,.56),(.052,.49),(.075,.435),(.12,.32),(.13,.15),(.08,.07),(0,.07)],72)
    asset('art_vase',[component('Ceramic_Form',vase,'Ceramic_Sage')],[.40,.586,.40],'display','artwork',label='Study 01 / vessel')
    loop=[]
    for i in range(129):
        a=i/128*2*math.pi;loop.append([.22*math.sin(a),.35+.27*math.cos(a),.045*math.sin(2*a)])
    art=[component('Loop',tube_curve(loop,.060,16),'Art_Brass'),component('Foot',bevel_box((.23,.065,.17),.014,(0,.0325,0)),'Art_Brass')]
    asset('art_loop',art,[.58,.68,.21],'display','artwork',label='Study 02 / continuous loop')

# ----- glTF 2.0 writer: no opaque compression, no proprietary extensions -----
class Writer:
    def __init__(self,tex):
        self.tex=tex;self.bin=bytearray();self.acache={};self.mcache={};self.meshcache={};self.imagecache={};self.tcache={}
        self.j={'asset':{'version':'2.0','generator':'MemoryMuseum deterministic modular kit / 1.0'},'scene':0,'scenes':[{'name':'MemoryMuseum','nodes':[]}],
                'nodes':[],'meshes':[],'materials':[],'textures':[],'images':[],'samplers':[{'magFilter':9729,'minFilter':9987,'wrapS':10497,'wrapT':10497}],
                'accessors':[],'bufferViews':[],'buffers':[{'byteLength':0}]}
    def buff(self,data,target=None):
        while len(self.bin)%4:self.bin.append(0)
        off=len(self.bin);self.bin.extend(data);v={'buffer':0,'byteOffset':off,'byteLength':len(data)}
        if target:v['target']=target
        self.j['bufferViews'].append(v);return len(self.j['bufferViews'])-1
    def accessor(self,a,kind,target):
        a=np.asarray(a);isindex=kind=='SCALAR';a=a.astype('<u4' if isindex else '<f4')
        view=self.buff(a.tobytes(),target);d={'bufferView':view,'componentType':5125 if isindex else 5126,'count':len(a),'type':kind}
        if not isindex:d['min']=a.min(axis=0).astype(float).tolist();d['max']=a.max(axis=0).astype(float).tolist()
        self.j['accessors'].append(d);return len(self.j['accessors'])-1
    def texture(self,path):
        if path in self.tcache:return self.tcache[path]
        data=(ROOT/path).read_bytes();mime='image/jpeg' if path.endswith('.jpg') else 'image/png'
        v=self.buff(data);self.j['images'].append({'bufferView':v,'mimeType':mime,'name':Path(path).stem})
        self.j['textures'].append({'sampler':0,'source':len(self.j['images'])-1})
        idx=len(self.j['textures'])-1;self.tcache[path]=idx;return idx
    def material(self,name):
        if name in self.mcache:return self.mcache[name]
        m=MATERIALS[name];pbr={'baseColorFactor':m['color'],'metallicFactor':m['metal'],'roughnessFactor':m['rough']}
        out={'name':name,'pbrMetallicRoughness':pbr}
        if m['texture']:
            tx=self.tex[m['texture']];pbr['baseColorTexture']={'index':self.texture(tx['baseColor'])};pbr['roughnessFactor']=1
            pbr['metallicRoughnessTexture']={'index':self.texture(tx['orm'])};out['normalTexture']={'index':self.texture(tx['normal']),'scale':1}
        if m['double']:out['doubleSided']=True
        if m['alpha']:out['alphaMode']=m['alpha']
        if m['emissive']:out['emissiveFactor']=m['emissive']
        self.j['materials'].append(out);idx=len(self.j['materials'])-1;self.mcache[name]=idx;return idx
    def mesh(self,mesh,material,name):
        key=(id(mesh),material)
        if key in self.meshcache:return self.meshcache[key]
        if id(mesh) not in self.acache:
            attrs={'POSITION':self.accessor(mesh.p,'VEC3',34962),'NORMAL':self.accessor(mesh.n,'VEC3',34962),'TEXCOORD_0':self.accessor(mesh.uv,'VEC2',34962)}
            vv=mesh.p[mesh.f];keep=np.linalg.norm(np.cross(vv[:,1]-vv[:,0],vv[:,2]-vv[:,0]),axis=1)>1e-12
            ind=self.accessor(mesh.f[keep].reshape(-1),'SCALAR',34963);self.acache[id(mesh)]=(attrs,ind)
        attrs,ind=self.acache[id(mesh)]
        self.j['meshes'].append({'name':name,'primitives':[{'attributes':attrs,'indices':ind,'material':self.material(material)}]})
        idx=len(self.j['meshes'])-1;self.meshcache[key]=idx;return idx
    def node(self,entry,parent=None):
        idx=len(self.j['nodes']);self.j['nodes'].append(entry)
        if parent is None:self.j['scenes'][0]['nodes'].append(idx)
        else:self.j['nodes'][parent].setdefault('children',[]).append(idx)
        return idx
    def instance(self,aid,name=None,pos=(0,0,0),rot=0,scale=(1,1,1),overrides=None,parent=None,extras=None):
        a=ASSETS[aid];data={'name':name or aid,'translation':list(pos),'rotation':[0,math.sin(rot/2),0,math.cos(rot/2)],'scale':list(scale),'extras':dict(a['extras'])}
        if extras:data['extras'].update(extras)
        idx=self.node(data,parent)
        for part in a['parts']:
            role=part['extras'].get('role','');mt=part['material'];mesh=part['mesh']
            if overrides:
                if role.startswith('wall') and 'wall' in overrides:mt=overrides['wall']
                elif role=='floor' and 'floor' in overrides:mt=overrides['floor']
            self.node({'name':part['name'],'mesh':self.mesh(mesh,mt,part['name']),'extras':part['extras']},idx)
        return idx
    def save(self,path):
        self.j['buffers'][0]['byteLength']=len(self.bin)
        js=json.dumps(self.j,separators=(',',':'),ensure_ascii=True).encode();js+=b' '*((-len(js))%4)
        self.bin+=b'\0'*((-len(self.bin))%4)
        total=12+8+len(js)+8+len(self.bin)
        path.write_bytes(struct.pack('<III',0x46546c67,2,total)+struct.pack('<II',len(js),0x4e4f534a)+js+struct.pack('<II',len(self.bin),0x004e4942)+self.bin)

# Layout coordinates: hub at origin; front is +Z, left is -X, right is +X.
DEFAULT={'schemaVersion':1,'kitVersion':'1.1.0-home','rooms':{
 'hub':{'enabled':True,'width':8,'depth':8,'wall':'plaster','floor':'oak'},
 'left':{'enabled':False,'width':6,'depth':6,'wall':'oak','floor':'oak'},
 'right':{'enabled':False,'width':6,'depth':6,'wall':'plaster','floor':'oak'},
 'front':{'enabled':False,'width':6,'depth':6,'wall':'brick','floor':'limestone'}},'objects':[]}

def layout_rooms(cfg):
    rooms=[];hub=cfg['rooms']['hub'];gap=1.24
    for rid,r in cfg['rooms'].items():
        if not r['enabled']:continue
        cx=cz=0
        if rid=='left':cx=-(hub['width']/2+r['width']/2+gap)
        elif rid=='right':cx=hub['width']/2+r['width']/2+gap
        elif rid=='front':cz=hub['depth']/2+r['depth']/2+gap
        doors=[]
        if rid=='hub':
            doors=[{'left':'west','right':'east','front':'south'}[k] for k in ('left','right','front') if cfg['rooms'][k]['enabled']]
        else:doors=[{'left':'east','right':'west','front':'north'}[rid]]
        rooms.append(dict(r,id=rid,x=cx,z=cz,doors=doors))
    return rooms

def room_instances(room):
    w,d=room['width'],room['depth'];rid=room['id'];res=[];c=np.array([room['x'],0,room['z']]);wallmat={'plaster':'Wall_Plaster','oak':'Wall_Oak','brick':'Wall_Brick','limestone':'Wall_Limestone'}[room['wall']]
    fm='Floor_Oak' if room['floor']=='oak' else 'Floor_Limestone'
    def put(aid,pos,rot=0,scale=(1,1,1),**extras):
        res.append(dict(aid=aid,name=f'{rid}__{aid}__{len(res):03}',pos=(np.array(pos)+c).tolist(),rot=rot,scale=scale,overrides={'wall':wallmat,'floor':fm},extras={'roomId':rid,**extras}))
    # One floor tile mesh, expanded through corrected physical UVs by the viewer;
    # static exporter uses individual 1 m tiles with consistent physical repeats.
    for x in np.arange(-w/2+.5,w/2,1):
        for z in np.arange(-d/2+.5,d/2,1):put('floor_1m',(x,0,z))
    for side,length,angle,pos in [('north',w,0,(0,0,-d/2-.12)),('south',w,math.pi,(0,0,d/2+.12)),('east',d,-math.pi/2,(w/2+.12,0,0)),('west',d,math.pi/2,(-w/2-.12,0,0))]:
        door=side in room['doors'];intervals=[(-length/2,-1.5),(1.5,length/2)] if door else [(-length/2,length/2)]
        m=matrix(pos,angle)
        if door:put('portal_arch_3m',pos,angle,side=side,portal=True)
        for lo,hi in intervals:
            q=lo
            while q<hi-.001:
                seg=min(1,hi-q);local=np.array([q+seg/2,0,0]);p=m[:3,:3]@local+m[:3,3]
                put('wall_1m' if seg>.75 else 'wall_05m',p,angle,side=side,cutaway=side in ['south','east']);q+=seg
    for x in [-w/2+.025,w/2-.025]:
        for z in [-d/2+.025,d/2-.025]:put('corner_post',(x,0,z),side='corner')
    return res

def default_objects():
    # Home Edition only: open living-room composition. Other rooms start disabled.
    # Rug overlaps furniture deliberately, and does not act as a collision obstacle.
    furniture=[]
    def add(a,r,x,z,rot=0):
        furniture.append({'id':f'home-{len(furniture)+1:03}', 'assetId':a,'roomId':r,'position':[x,0,z],'rotationY':rot})
    add('home_rug','hub',.05,-.6)
    add('home_sofa','hub',0,-2.45)
    add('home_coffee_table','hub',.05,-.65)
    add('home_display_shelf','hub',-2.82,1.45,math.pi/2)
    add('home_console','hub',2.70,1.55,-math.pi/2)
    add('home_floor_lamp','hub',2.86,-2.88)
    add('plant','hub',-3.08,-2.99)
    return furniture

if __name__=='__main__':
    if '--reuse-textures' in sys.argv:
        print('Reusing original texture set...',flush=True)
        tex=json.loads((ROOT/'config/materials.json').read_text())
    else:
        print('Generating original PBR textures...',flush=True)
        tex=build_textures();(ROOT/'config/materials.json').write_text(json.dumps(tex,indent=2))
    print('Modelling kit...',flush=True);build_assets()
    catalog=[]
    lib=Writer(tex)
    for aid,a in ASSETS.items():
        wr=Writer(tex);wr.instance(aid);wr.save(OUT/f'{aid}.glb');lib.instance(aid)
        bounds=np.array([p['mesh'].p for p in a['parts']],dtype=object) if False else np.concatenate([p['mesh'].p for p in a['parts']])
        catalog.append({'id':aid,'name':a['label'],'file':f'assets/modules/{aid}.glb','category':a['category'],'placement':a['placement'],
                        'dimensionsMeters':a['size'],'bounds':[bounds.min(0).tolist(),bounds.max(0).tolist()],
                        'triangles':sum(len(p['mesh'].f) for p in a['parts']),'origin':'bottom-center',
                        'topAnchor':[0,a['size'][1],0] if aid.startswith('plinth_') else None})
        print(aid,catalog[-1]['triangles'],flush=True)
    for material_name in MATERIALS: lib.material(material_name)
    lib.save(ROOT/'assets/modular_kit.glb')
    cfg=copy.deepcopy(DEFAULT)
    cfg['objects']=default_objects()
    for entry in catalog:
        if entry['id']=='home_rug':entry['layer']='floor_decor'
        if entry['id'] in ['home_coffee_table','home_console','home_craft_desk','home_display_shelf']:
            entry['topAnchor']=[0,entry['dimensionsMeters'][1],0]
    (ROOT/'config/default-layout.json').write_text(json.dumps(cfg,indent=2))
    (ROOT/'config/asset-catalog.json').write_text(json.dumps(catalog,indent=2))
    # The browser builder exports the fully configured assembly as glTF.
    print('Kit ready.',flush=True)
