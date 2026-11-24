'use strict';
const canvas = document.querySelector('canvas');
const status = document.querySelector('#status');
const gl = canvas.getContext('webgl', {antialias:true, alpha:false});
if (!gl) {
  status.hidden = false;
  status.textContent = 'WebGL unavailable; use classic 2D.';
  if(window.parent!==window)window.parent.postMessage({type:'reflex-ocean-error'},location.origin);
} else {
  try { ocean(); } catch (error) {
    status.hidden = false;
    status.textContent = 'The 3D scene could not start.';
    console.error(error);
    if(window.parent!==window)window.parent.postMessage({type:'reflex-ocean-error'},location.origin);
  }
}
function ocean() {
  const arenaMode=true; document.body.classList.add("arena");
  const shadowProjection = `
    const vec2 lightSlope=vec2(.42,.37);
    const vec2 lightSpan=vec2(166.,156.);
    const float lightDepth=36.;
    vec2 lightUV(vec3 p){
      return (p.xz+p.y*lightSlope+vec2(0.,27.))/lightSpan+.5;
    }
    float shadowDepthAt(vec3 p){return (6.-p.y)/lightDepth;}
  `;
  const vertex = `
    precision highp float;
    attribute vec3 position, normal, color;
    uniform vec3 eye, right, up, forward;
    uniform vec2 lens;
    uniform float time, sway, mode;
    varying vec3 point, tint, n;
    ${shadowProjection}
    void main() {
      point=position;
      point.xz+=sway*max(0.,position.y+19.)*.032*vec2(sin(time*1.4+position.y*.63+position.x),cos(time+position.z));
      vec3 p=point-eye;
      float z=dot(p,forward);
      gl_Position=vec4(dot(p,right)*lens.x,dot(p,up)*lens.y,1.0011*z-.1601,z);
      if(mode==3.){
        gl_Position=vec4(lightUV(point)*2.-1.,shadowDepthAt(point)*2.-1.,1.);
      }
      tint=color; n=normal;
      gl_PointSize=clamp(28./max(z,.5),1.,5.);
    }`;
  const derivatives=Boolean(gl.getExtension('OES_standard_derivatives'));
  const fragment = `
    ${derivatives?'#extension GL_OES_standard_derivatives : enable':''}
    precision highp float;
    uniform vec3 eye, forward;
    uniform vec4 ping;
    uniform float lamp;
    uniform float time, mode;
    uniform sampler2D shadows;
    uniform float shadowTexel;
    ${shadowProjection}
    varying vec3 point, tint, n;
    const vec3 sun=vec3(-.366,.872,-.323);
    const vec3 deep=vec3(.018,.106,.157);
    const vec3 horizon=vec3(.028,.207,.273);

    float hash(vec3 p){
      p=fract(p*.1031);
      p+=dot(p,p.yzx+33.33);
      return fract((p.x+p.y)*p.z);
    }
    float noise(vec3 p){
      vec3 i=floor(p),f=fract(p);
      f=f*f*(3.-2.*f);
      return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),
                     mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),
                 mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),
                     mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);
    }
    float blockerDepth(vec2 uv){
      vec2 encoded=texture2D(shadows,uv).rg;
      return dot(encoded,vec2(1.,1./255.));
    }
    float softShadow(vec3 p,vec3 normal,float diffuse){
      vec2 uv=lightUV(p);
      float receiver=shadowDepthAt(p);
      float nearest=blockerDepth(uv);
      float separation=max(0.,receiver-nearest)*lightDepth;
      float radius=mix(1.35,3.65,smoothstep(.25,5.,separation))*shadowTexel;
      float bias=mix(.0048,.00155,diffuse);
      float incidence=dot(normal,vec3(-lightSlope.x,1.,-lightSlope.y));
      vec2 depthSlope=normal.xz*lightSpan/(lightDepth*max(.35,incidence));
      float light=0.;
      for(int j=-1;j<=1;j++){
        for(int i=-1;i<=1;i++){
          vec2 offset=vec2(float(i),float(j))*radius;
          float plane=clamp(dot(offset,depthSlope),-.019,.019);
          float weight=(2.-abs(float(i)))*(2.-abs(float(j)));
          light+=weight*step(receiver+plane-bias,blockerDepth(uv+offset));
        }
      }
      return light/16.;
    }
    float ripple(vec2 p){
      return sin(p.x*.66+p.y*.58+sin(p.y*.72+time*.58)*1.7+time*.59)
           + sin(p.y*1.07-p.x*.47+cos(p.x*.37-time*.44)*1.45-time*.76)
           + .5*sin(p.x*.36+p.y*1.51+time*.68);
    }
    vec3 scatter(vec3 ray,float d){
      float range=min(d,78.);
      float shafts=0.;
      float mist=0.;
      for(int i=0;i<8;i++){
        vec3 p=eye+ray*range*(float(i)+.5)/8.;
        vec2 uv=lightUV(p);
        vec2 surfacePoint=p.xz+p.y*lightSlope;
        float beamCore=exp(-dot((surfacePoint-vec2(-2.,-17.))*vec2(.125,.065),(surfacePoint-vec2(-2.,-17.))*vec2(.125,.065)));
        float lensing=.29+.64*pow(.5+.5*sin(uv.x*255.+sin(uv.y*143.+time*.27)*1.8),4.)+1.36*beamCore;
        float blocked=shadowDepthAt(p)-blockerDepth(uv);
        float sunlit=1.-smoothstep(-.012,.028,blocked);
        float veil=.5+.5*sin(p.z*.12+p.x*.13+sin(p.x*.105-p.y*.26+time*.13)*1.5);
        float nearBed=smoothstep(9.,25.,-p.y);
        mist+=nearBed*(.33+veil*.67);
        shafts+=lensing*sunlit*exp(min(0.,p.y)*.060);
      }
      float glow=pow(max(0.,dot(ray,sun)),4.);
      float murk=mist/8.;
      vec3 waterHaze=mix(mix(deep,horizon,smoothstep(-.4,.54,ray.y)),vec3(.035,.14,.185),murk*.68);
      return waterHaze*(1.-exp(-d*(.033+.023*murk)))
           +vec3(.11,.52,.57)*(shafts/8.)*(1.-exp(-range*.052))*(.65+glow*1.25);
    }
    void main(){
      if(mode==3.){
        float depth=gl_FragCoord.z;
        vec2 encoded=fract(depth*vec2(1.,255.));
        gl_FragColor=vec4(encoded.x-encoded.y/255.,encoded.y,0.,1.);
        return;
      }
      vec3 ray=point-eye;
      float d=length(ray);
      vec3 direction=ray/max(d,.001);
      if(mode==2.){
        vec2 p=gl_PointCoord-.5;
        float a=exp(-dot(p,p)*17.)*exp(-d*.079)*smoothstep(.3,2.,d);
        gl_FragColor=vec4(.61,.91,.83,a*.52); return;
      }
      vec3 fog=scatter(direction,d);
      if(mode==1.){
        vec2 p=point.xz;
        float base=ripple(p);
        vec3 wave=normalize(vec3((ripple(p+vec2(.19,0.))-base)*.68,1.,(ripple(p+vec2(0.,.19))-base)*.68));
        float incidence=max(0.,dot(wave,direction));
        float windowMask=smoothstep(.59,.73,incidence);
        float fresnel=pow(1.-incidence,3.);
        float glint=pow(max(0.,dot(reflect(-sun,wave),direction)),29.);
        float corona=pow(max(0.,dot(direction,sun)),11.);
        float fine=ripple(p*2.4+vec2(7.1,-4.4));
        float seam=exp(-abs(base+.24*fine)*6.);
        vec3 reflectedWater=mix(vec3(.027,.19,.27),vec3(.10,.39,.46),fresnel)+seam*vec3(.047,.13,.16);
        vec3 daylight=mix(vec3(.16,.50,.59),vec3(.43,.72,.75),.48+fine*.13);
        vec3 waterColor=mix(reflectedWater,daylight,windowMask);
        waterColor+=vec3(.63,.74,.59)*(glint*.83+corona*.77)*(.52+.48*windowMask);
        gl_FragColor=vec4(mix(waterColor+fog*.27,horizon,smoothstep(57.,140.,d)),1.);return;
      }
      vec3 echo=vec3(0.);
      if(ping.w>=0.){
        float shell=abs(length(point-ping.xyz)-ping.w);
        float sonar=exp(-shell*6.)*.78+exp(-shell*1.6)*.23;
        echo=vec3(.055,.77,1.)*sonar*(1.-smoothstep(28.,53.,ping.w));
      }
      if(mode==6.){
        float rim=pow(1.-abs(dot(normalize(n),direction)),2.5);
        gl_FragColor=vec4(tint*(.34+rim*.87)*exp(-d*.027)+fog*.38+echo,1.);return;
      }
      vec3 normal=normalize(mode==5.&&!gl_FrontFacing?-n:n);
      float diffuse=max(0.,dot(normal,sun));
      vec3 receiverNormal=normal;
      ${derivatives?`
        vec3 planeNormal=cross(dFdx(point),dFdy(point));
        float planeLength=length(planeNormal);
        if(planeLength>1e-10){
          receiverNormal=planeNormal/planeLength;
          if(dot(receiverNormal,normal)<0.)receiverNormal=-receiverNormal;
        }
      `:''}
      float lit=softShadow(point,receiverNormal,diffuse);
      vec2 projected=point.xz+point.y*lightSlope;
      float a=ripple(projected);
      float b=ripple(projected*.67+vec2(3.2,-5.8));
      float caustic=exp(-7.*abs(a*b))*.66+exp(-8.*abs(a+.23))*.34;
      float strata=noise(point*vec3(.42,2.7,.51));
      float rough=noise(point*.88)*.66+noise(point*2.08)*.25+noise(point*5.2)*.09;
      float grit=mix(.51,1.55,smoothstep(.14,.86,rough))*(.76+.35*strata);
      float atten=exp(point.y*.029);
      float skyFacing=.45+.55*max(0.,normal.y);
      vec3 ambient=mix(vec3(.045,.155,.223),vec3(.14,.32,.40),lit)*skyFacing;
      float halfSpec=pow(max(0.,dot(normal,normalize(sun-direction))),36.);
      vec3 sunlight=vec3(.78,1.31,1.34)*atten*lit*(.12+diffuse*1.47+caustic*1.12);
      vec3 sparkle=vec3(.11,.24,.25)*halfSpec*atten*lit;
      vec3 reflected=vec3(.004,.026,.031)*pow(1.-abs(dot(normal,direction)),3.);
      vec3 shade=tint*grit*(ambient+sunlight)+reflected+sparkle;
      if(mode==5.){
        float transmitted=max(0.,-dot(normal,sun));
        float silk=pow(max(0.,dot(normal,normalize(sun-direction))),16.);
        shade+=tint*vec3(1.19,.79,.28)*(lit*(transmitted*.72+silk*.55)+.055);
      }
      float cone=smoothstep(.87,.991,dot(direction,forward));
      float torch=lamp*cone*exp(-d*.061)*(.38+.95*max(0.,dot(normal,-direction)));
      shade+=torch*(tint*vec3(.93,1.39,1.64)+vec3(.021,.043,.053));
      shade+=echo;
      if(mode==8.||mode==9.){
        float shimmer=pow(1.-abs(dot(normal,direction)),3.);
        shade+=vec3(.087,.18,.20)*shimmer*(.44+.56*lit)*(mode==9.?.61:1.);
      }
      float haze=1.-exp(-d*.079);
      fog*=mix(.76+.10*lit,1.,haze);
      float density=1.+.31*smoothstep(8.,24.,-(eye.y+point.y)*.5);
      gl_FragColor=vec4(shade*exp(-d*density*vec3(.057,.032,.026))+fog,1.);
    }`;
  function shader(type, source) {
    const result = gl.createShader(type);
    gl.shaderSource(result,source); gl.compileShader(result);
    if (!gl.getShaderParameter(result,gl.COMPILE_STATUS)) throw Error(gl.getShaderInfoLog(result));
    return result;
  }
  const program=gl.createProgram();
  gl.attachShader(program,shader(gl.VERTEX_SHADER,vertex));
  gl.attachShader(program,shader(gl.FRAGMENT_SHADER,fragment));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program,gl.LINK_STATUS)) throw Error(gl.getProgramInfoLog(program));
  gl.useProgram(program);
  const uniforms=Object.fromEntries(['eye','right','up','forward','lens','time','sway','mode','shadows','shadowTexel','ping','lamp'].map(key=>[key,gl.getUniformLocation(program,key)]));
  const attributes=['position','normal','color'].map(key=>gl.getAttribLocation(program,key));
  attributes.forEach(index=>gl.enableVertexAttribArray(index));
  gl.enable(gl.DEPTH_TEST);

  const shadowSize=Math.min(2048,gl.getParameter(gl.MAX_TEXTURE_SIZE),gl.getParameter(gl.MAX_RENDERBUFFER_SIZE));
  function texture(size, pixels=null){
    const result=gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D,result);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,size,size,0,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    return result;
  }
  const shadowMap=texture(shadowSize);
  const white=texture(1,new Uint8Array([255,255,255,255]));
  const shadowDepth=gl.createRenderbuffer();
  gl.bindRenderbuffer(gl.RENDERBUFFER,shadowDepth);
  gl.renderbufferStorage(gl.RENDERBUFFER,gl.DEPTH_COMPONENT16,shadowSize,shadowSize);
  const shadowTarget=gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER,shadowTarget);
  gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,shadowMap,0);
  gl.framebufferRenderbuffer(gl.FRAMEBUFFER,gl.DEPTH_ATTACHMENT,gl.RENDERBUFFER,shadowDepth);
  const hasShadows=gl.checkFramebufferStatus(gl.FRAMEBUFFER)===gl.FRAMEBUFFER_COMPLETE;
  gl.bindFramebuffer(gl.FRAMEBUFFER,null);
  gl.uniform1i(uniforms.shadows,0);
  gl.uniform1f(uniforms.shadowTexel,1/shadowSize);

  const add=(a,b)=>a.map((v,i)=>v+b[i]);
  const sub=(a,b)=>a.map((v,i)=>v-b[i]);
  const scale=(a,s)=>a.map(v=>v*s);
  const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
  const unit=a=>scale(a,1/(Math.hypot(...a)||1));
  let seed=91304;
  function random(){ seed=(Math.imul(seed,1664525)+1013904223)>>>0; return seed/4294967296; }
  const range=(a,b)=>a+(b-a)*random();
  const bank=z=>Math.sin(z*.072)*5;
  const openingShot={from:[0,-16.6,6.6],to:[0,-11.9,-3.5],aim:[.25,-19,-10],seconds:13};
  function inOpeningPassage(x,z){
    // Clearance includes the reach of the leaves and their maximum shader sway.
    return Math.hypot(x,z-Math.max(-3.5,Math.min(7,z)))<3.5;
  }
  const forum=[-35,-57];
  const inForum=(x,z)=>Math.abs(x-forum[0])<13&&Math.abs(z-forum[1])<12;
  function floor(x,z) {
    const canyon=Math.abs(x-bank(z));
    const wall=Math.min(1,Math.max(0,(canyon-6)/20));
    const ridges=(.52+.48*Math.sin(z*.12+.6*Math.sin(x*.19)))*(.57+.43*Math.sin(x*.23-z*.041));
    const fade=Math.exp(-Math.max(0,-z-18)*.051);
    const shelf=3.1*Math.exp(-((x-15)**2/165+(z+41)**2/650));
    const basin=-5.4*Math.exp(-((x-19)**2/255+(z+62)**2/213));
    const terrace=2.4*Math.exp(-((x+30)**2/210+(z+28)**2/310));
    const ground=-21+shelf+basin+terrace + wall*(2.1+15*ridges)*fade + Math.sin(x*.19+z*.14)*.9+Math.cos(z*.27-x*.37)*.69+Math.sin(x*.83+z*.65)*.28;
    const apron=Math.max(Math.abs(x-forum[0])/12,Math.abs(z-forum[1])/11);
    const blend=Math.max(0,Math.min(1,(1.24-apron)*3.05));
    return ground+(-20.5-ground)*blend;
  }
  let land=[], plants=[], surface=[], dust=[];
  function put(out,p,n,c){out.push(...p,...n,...c);}
  function tri(out,a,b,c,t,normals) {
    const n=unit(cross(sub(b,a),sub(c,a)));
    put(out,a,normals?.[0]??n,t); put(out,b,normals?.[1]??n,t); put(out,c,normals?.[2]??n,t);
  }
  function quad(out,a,b,c,d,t){tri(out,a,b,c,t);tri(out,a,c,d,t);}
  const stone=[.16,.32,.32], sand=[.31,.42,.36], iron=[.27,.22,.17];
  const normalAt=(x,z)=>unit([floor(x-.4,z)-floor(x+.4,z),.8,floor(x,z-.4)-floor(x,z+.4)]);
  for(let x=-82;x<82;x+=1.2) for(let z=-102;z<48;z+=1.2){
    const a=[x,floor(x,z),z],b=[x,floor(x,z+1.2),z+1.2],c=[x+1.2,floor(x+1.2,z+1.2),z+1.2],d=[x+1.2,floor(x+1.2,z),z];
    const t=scale(Math.abs(x-bank(z))<6||z<-36?sand:stone,range(.77,1.23));
    const [na,nb,nc,nd]=[a,b,c,d].map(p=>normalAt(p[0],p[2]));
    tri(land,a,b,c,t,[na,nb,nc]);tri(land,a,c,d,t,[na,nc,nd]);
  }
  function beam(out,a,b,r,t,sides=6,endRadius=r){
    const axis=unit(sub(b,a));
    const u=unit(cross(axis,Math.abs(axis[1])>.93?[1,0,0]:[0,1,0])),v=cross(axis,u);
    const ring=Array.from({length:sides},(_,i)=>add(scale(u,Math.cos(i*6.283/sides)),scale(v,Math.sin(i*6.283/sides))));
    for(let i=0;i<sides;i++){
      const p=ring[i],q=ring[(i+1)%sides];
      quad(out,add(a,scale(q,r)),add(a,scale(p,r)),add(b,scale(p,endRadius)),add(b,scale(q,endRadius)),scale(t,.84+i/sides*.29));
    }
  }
  const rocks=[];
  function boulder(x,y,z,rx,ry,rz){
    rocks.push({center:[x,y,z],radii:[rx*.88+.35,ry*.9+.35,rz*.88+.35]});
    const rings=Array.from({length:12},(_,j)=>Array.from({length:20},(_,i)=>{
      const a=i*Math.PI/10+j*.1,b=j*Math.PI/11;
      const k=1+.16*Math.sin(a*3.+z+b*4.)+.09*Math.sin(a*7.+b*8.+x);
      return [x+Math.cos(a)*Math.sin(b)*rx*k,
              y+Math.cos(b)*ry+Math.sin(a*4.+b*3.)*ry*.085*Math.sin(b),
              z+Math.sin(a)*Math.sin(b)*rz*k];
    }));
    const normals=rings.map((ring,j)=>ring.map((p,i)=>{
      if(j===0||j===11)return [0,j===0?1:-1,0];
      return unit(cross(sub(ring[(i+1)%20],ring[(i+19)%20]),sub(rings[j+1][i],rings[j-1][i])));
    }));
    for(let j=0;j<11;j++)for(let i=0;i<20;i++){
      const next=(i+1)%20;
      const a=rings[j][i],b=rings[j][next],c=rings[j+1][next],d=rings[j+1][i];
      const na=normals[j][i],nb=normals[j][next],nc=normals[j+1][next],nd=normals[j+1][i];
      const color=scale(stone,.96+.087*Math.sin(j*2.5+x)+.055*Math.sin(i*.62+z));
      tri(land,a,b,c,color,[na,nb,nc]);tri(land,a,c,d,color,[na,nc,nd]);
    }
  }
  for(let i=0;i<320;i++){
    const z=range(-85,38), x=range(-65,65);
    if(inForum(x,z)||Math.abs(x-bank(z))<5||Math.hypot(x-20,z+58)<11||Math.hypot(x+25,z+26)<10)continue;
    const r=range(.55,4.4);
    boulder(x,floor(x,z)-.3,z,r,range(.65,1.45)*r,r*range(.68,1.28));
  }
  boulder(-13,-17,-9,6,7,8);
  boulder(10,-15,-15,5.5,8,7.5);
  boulder(8,-8,-19,5,4.8,5);
  boulder(10,-6,2,5.7,7.4,5.6);
  boulder(-9,-5,-6,4.2,5.5,7.1);
  boulder(-10,-14,4,4.7,5.1,6.1);
  boulder(15,-13,-10,6.7,6.3,7.4);
  for(let i=0;i<210;i++){
    const x=range(-40,42),z=range(-80,26),y=floor(x,z);
    if(inForum(x,z)||inOpeningPassage(x,z)||Math.abs(x-bank(z))<4 || (Math.abs(x+15)<9&&Math.abs(z+47)<7))continue;
    if(i%3===0){
      const coral=i%2?[.57,.26,.45]:[.66,.35,.22];
      for(let j=0;j<5;j++){
        const end=[x+range(-.65,.65), y+range(.7,2.2), z+range(-.65,.65)];
        const fork=[x+range(-.3,.3),y+range(.45,.7),z+range(-.3,.3)];
        beam(land,[x,y,z],fork,.12,coral,5,.075);
        beam(land,fork,end,.08,coral,5,.038);
        beam(land,add(fork,scale(sub(end,fork),.48)),add(end,[range(-.55,.55),-.26,range(-.55,.55)]),.055,coral,5,.026);
      }
    }else{
      const h=Math.min(range(3,11),-y-.7), t=scale([.19,.42,.23],range(.65,1.32));
      let a=[x,y,z];
      for(let j=1;j<=7;j++){
        const b=[x+Math.sin(j*.48+x)*j*.12,y+h*j/7,z+Math.cos(j*.65+z)*j*.11];
        beam(plants,a,b,.064,t,4,.045);
        const side=j%2?1:-1;
        const tip=add(a,[side*range(.5,1.3),h*.17,range(-.56,.56)]);
        const mid=add(scale(add(a,tip),.5),[0,-.18,.22]);
        tri(plants,a,mid,tip,t);tri(plants,a,tip,mid,t);tri(plants,mid,b,tip,t);tri(plants,mid,tip,b,t);
        a=b;
      }
    }
  }

  // Curled blades spiral around each stem and catch light on their raised midribs.
  function blade(origin,angle,length,width,lift,tone,phase){
    const along=[Math.cos(angle),0,Math.sin(angle)],across=[-along[2],0,along[0]];
    const rows=Array.from({length:7},(_,j)=>{
      const u=j/6, profile=Math.pow(Math.sin(Math.PI*u),.83);
      const middle=add(origin,add(scale(along,u*length),[0,lift*u+Math.sin(u*Math.PI)*length*.29,0]));
      return [-1,0,1].map(side=>{
        const edge=Math.sin(u*17+phase+side)*width*.24*profile;
        return add(middle,add(scale(across,side*width*profile),[0,side?edge-width*.32*profile:width*.16*profile,0]));
      });
    });
    const normals=rows.map((row,j)=>row.map((point,k)=>{
      const tangent=sub(rows[Math.min(6,j+1)][k],rows[Math.max(0,j-1)][k]);
      const chord=length*.05;
      const neighbor=rows[j===0?1:j===6?5:j];
      return unit(cross(tangent,add(sub(neighbor[Math.min(2,k+1)],neighbor[Math.max(0,k-1)]),[0,chord*.04,0])));
    }));
    for(let j=0;j<6;j++)for(let k=0;k<2;k++){
      const color=scale(tone,.82+.21*Math.sin(j*.55+phase)+k*.16);
      const a=rows[j][k],b=rows[j+1][k],c=rows[j+1][k+1],d=rows[j][k+1];
      const na=normals[j][k],nb=normals[j+1][k],nc=normals[j+1][k+1],nd=normals[j][k+1];
      tri(plants,a,b,c,color,[na,nb,nc]);tri(plants,a,c,d,color,[na,nc,nd]);
    }
  }
  function kelpPlant(x,z,height,phase){
    const y=floor(x,z);
    const tone=scale([.21,.41,.125],range(.61,1.28));
    height=Math.min(-y-.55,height);
    const steps=16;
    const stem=j=>[x+Math.sin(j*.32+phase)*j*.058,y+height*j/steps,z+Math.cos(j*.29+phase)*j*.051];
    for(let j=0;j<steps;j++){
      const a=stem(j),b=stem(j+1);
      const taper=1-j/steps*.61;
      beam(plants,a,b,.072*taper,tone,4,.065*taper);
      const angle=j*2.399+phase;
      for(let k=0;k<3;k++){
        const length=range(.65,1.65)*(.63+.45*Math.sin(Math.PI*j/steps))*(k===2?.66:1);
        blade(add(a,scale(sub(b,a),k*.23)),angle+k*2.05,length,length*range(.18,.27),range(.22,.77),tone,phase+k);
      }
    }
  }
  const beds=[
    [-6,-4,6,12,29],[5,-8,5,16,30],[-6,-22,5,15,25],[7,-28,6,11,21],
    [-14,-31,7,11,16],[14,-42,6,9,17],[-3,-51,6,8,12]
  ];
  for(const [bx,bz,rx,rz,count] of beds)for(let i=0;i<count;i++){
    const z=bz+range(-rz,rz),x=bx+range(-rx,rx);
    if(inOpeningPassage(x,z)||Math.abs(x-bank(z)*.41)<2.5)continue;
    kelpPlant(x,z,range(10,23),range(0,6.28));
  }
  for(let i=0;i<38;i++){
    const x=range(-23,27),z=range(-53,13);
    if(inOpeningPassage(x,z)||Math.abs(x-bank(z)*.41)<3)continue;
    const y=floor(x,z)+.16,phase=range(0,6.28);
    for(let j=0;j<11;j++){
      const length=range(.55,1.58);
      blade([x,y,z],phase+j*2.399,length,length*.15,range(.42,1.22),[.28,.49,.19],phase+j);
    }
  }

  // Stone flukes rise out of the sand at the far end of the kelp passage.
  const tailX=2,tailZ=-32,tailY=floor(tailX,tailZ);
  const tailStone=[.28,.47,.43];
  function stoneSweep(section,axis,steps){
    const rings=Array.from({length:steps+1},(_,j)=>{
      const {center,radii}=section(j/steps);
      if(j%2===0&&Math.min(...radii)>.15)rocks.push({center,radii});
      return Array.from({length:20},(_,i)=>{
        const angle=i*Math.PI/10;
        const roughness=1+.07*Math.sin(j*1.1+angle*5.);
        const offset=axis===0?[0,Math.cos(angle)*radii[1],Math.sin(angle)*radii[2]]
                            :[Math.cos(angle)*radii[0],0,Math.sin(angle)*radii[2]];
        return {position:add(center,scale(offset,roughness)),normal:unit(offset.map((value,k)=>value/(radii[k]**2)))};
      });
    });
    for(let j=0;j<steps;j++)for(let i=0;i<20;i++){
      const k=(i+1)%20;
      const [a,b,c,d]=[rings[j][i],rings[j][k],rings[j+1][k],rings[j+1][i]];
      tri(land,a.position,b.position,c.position,tailStone,[a.normal,b.normal,c.normal]);
      tri(land,a.position,c.position,d.position,tailStone,[a.normal,c.normal,d.normal]);
    }
  }
  stoneSweep(u=>({
    center:[tailX+u*.4,tailY-.45+u*7.2,tailZ+u*u*1.5],
    radii:[1.69-.67*u,.78,1.33-.42*u]
  }),1,20);
  for(const sign of [-1,1]){
    stoneSweep(u=>({
      center:[tailX+.4+sign*u*7.8,tailY+6.5+3.35*u**2.6,tailZ+1.5-2.01*u*u],
      radii:[.58,Math.max(.024,(1-u)**.69*(.87+.32*Math.sin(Math.PI*u))),Math.max(.03,(1-u)**.73*(1.52+.93*Math.sin(Math.PI*u)))],
    }),0,23);
  }
  const crystals=[], grotto=[-25,-26], vents=[20,-58];
  const [gx,gz]=grotto, gy=floor(gx,gz);
  for(let i=0;i<=10;i++){
    const a=i*Math.PI/10;
    const x=gx+Math.cos(a)*7.9;
    boulder(x,floor(x,gz)+Math.sin(a)*8.7,gz,2.7,3.0,3.8);
  }
  for(let i=0;i<37;i++){
    const x=gx+range(-9,9),z=gz+range(-9,3),y=floor(x,z);
    for(let j=0;j<range(2,5);j++){
      const root=[x+range(-.43,.43),y-.2,z+range(-.43,.43)];
      const tip=add(root,[range(-.5,.5),range(.53,2.05),range(-.5,.5)]);
      const color=j%2?[.16,.77,.83]:[.51,.33,.89];
      beam(crystals,root,tip,range(.12,.29),color,5,.07);
      beam(crystals,tip,add(tip,[.03,.22,.05]),.07,color,5,.012);
    }
  }
  const chimneys=[];
  for(let i=0;i<14;i++){
    const x=vents[0]+range(-8,8),z=vents[1]+range(-9,9),y=floor(x,z),h=range(1.1,5.0);
    const tip=[x+range(-.38,.38),y+h,z+range(-.38,.38)];
    beam(land,[x,y-.5,z],tip,h*.24,[.22,.29,.30],9,h*.11);
    boulder(x,y-.25,z,h*.49,h*.31,h*.49);
    chimneys.push(tip);
    for(let j=0;j<6;j++){
      const a=j*Math.PI/3;
      const root=add(tip,[Math.cos(a)*h*.11,-.05,Math.sin(a)*h*.11]);
      beam(crystals,root,add(root,[0,.15,0]),.07,[.66,.36,.12],5,.02);
    }
  }
  const jellyOrigins=Array.from({length:13},()=>[gx+range(-5,5),gy+range(3.7,8),gz+range(-9,-2)]);

  const [forumX,forumZ]=forum;
  const forumY=-20.5;
  const marble=[.44,.53,.49], aged=[.28,.39,.36];
  function block(out,x,y,z,width,height,depth,color){
    const lx=x-width/2,rx=x+width/2,ly=y-height/2,ry=y+height/2,lz=z-depth/2,rz=z+depth/2;
    const [a,b,c,d]=[[lx,ly,lz],[rx,ly,lz],[rx,ly,rz],[lx,ly,rz]];
    const [e,f,g,h]=[[lx,ry,lz],[rx,ry,lz],[rx,ry,rz],[lx,ry,rz]];
    quad(out,e,h,g,f,color);
    quad(out,a,e,f,b,color);quad(out,b,f,g,c,color);
    quad(out,c,g,h,d,color);quad(out,d,h,e,a,color);
  }
  const mosaic=[[.17,.32,.35],[.48,.52,.43],[.51,.31,.24],[.22,.38,.41]];
  for(let iz=-12;iz<=12;iz++)for(let ix=-16;ix<=16;ix++){
    const ring=Math.max(Math.abs(ix),Math.abs(iz));
    const radial=Math.hypot(ix,iz);
    const band=radial<2.1?2:radial<4.9?1:radial<6.3?0:
      ring===11||ring===12||Math.abs(ix)===15?2:(ix+iz+40)%2?1:3;
    const x=forumX+ix*.63,z=forumZ+iz*.63;
    if(random()<.085)continue;
    block(land,x,forumY+.09,z,range(.55,.625),.24,.61,scale(mosaic[band],range(.72,1.19)));
  }
  for(const side of [-1,1]){
    for(let row=0;row<5;row++){
      const x=forumX+side*8.1,z=forumZ+5.8-row*3.12,y=forumY+.2;
      const height=[5.35,3.02,5.75,1.72,4.95][(row+(side===1?1:0))%5];
      block(land,x,y+.17,z,1.79,.35,1.79,marble);
      block(land,x,y+.42,z,1.39,.17,1.39,aged);
      const foot=[x,y+.48,z], top=[x+side*.12,y+height,z-.13];
      beam(land,foot,top,.65,marble,16,.53);
      for(let j=0;j<12;j++){
        const a=j*Math.PI/6;
        const rim=[Math.cos(a),0,Math.sin(a)];
        beam(land,add(foot,scale(rim,.55)),add(top,scale(rim,.46)),.138,aged,4,.097);
      }
      if(height>4)block(land,x+side*.12,y+height,z-.13,1.49,.28,1.4,marble);
      rocks.push({center:[x,y+height*.49,z],radii:[.67,height*.53,.67]});
    }
  }
  function archBlock(angle){
    const section=(a,r,d)=>[forumX+Math.cos(a)*r,forumY+3.1+Math.sin(a)*r,forumZ-7.3+d];
    const a=angle-.09,b=angle+.09;
    const ring=[section(a,2.98,-.5),section(b,2.98,-.5),section(b,3.86,-.5),section(a,3.86,-.5),
                section(a,2.98,.5),section(b,2.98,.5),section(b,3.86,.5),section(a,3.86,.5)];
    const tint=scale(marble,range(.79,1.13));
    for(const [i,j,k,l] of [[0,1,2,3],[4,7,6,5],[0,4,5,1],[3,2,6,7],[0,3,7,4],[1,5,6,2]]){
      quad(land,ring[i],ring[j],ring[k],ring[l],tint);
    }
  }
  for(let i=0;i<16;i++){
    const angle=(i+.5)*Math.PI/16;
    archBlock(angle);
    if(i%2===0)rocks.push({
      center:[forumX+Math.cos(angle)*3.42,forumY+3.1+Math.sin(angle)*3.42,forumZ-7.3],
      radii:[.48,.48,.61]
    });
  }
  for(const side of [-1,1]){
    const x=forumX+side*3.41;
    block(land,x,forumY+1.52,forumZ-7.3,1.02,3.08,1.18,marble);
    rocks.push({center:[x,forumY+1.51,forumZ-7.3],radii:[.61,1.55,.65]});
  }
  for(let i=0;i<27;i++){
    const side=i%2===0?-1:1;
    const x=forumX+side*range(8.7,11.3),z=forumZ+range(-8,8);
    const y=floor(x,z);
    block(land,x,y+.15,z,range(.43,1.3),range(.27,.61),range(.43,.92),scale(aged,range(.65,1.3)));
    if(i%3===0){
      const clay=scale([.60,.29,.17],range(.72,1.14));
      beam(land,[x,y+.22,z],[x,y+.44,z],.13,clay,10,.31);
      beam(land,[x,y+.44,z],[x,y+.83,z],.31,clay,10,.18);
      beam(land,[x,y+.83,z],[x,y+.97,z],.14,clay,10,.16);
    }
  }

  for(const [x,z] of [[-5,7],[5,6],[-7,1],[7,-2],[-5,-6],[5,-6],[-2,-9],[3,-9]]){
    const root=[forumX+x,floor(forumX+x,forumZ+z)+.11,forumZ+z];
    for(let j=0;j<7;j++){
      const angle=j*Math.PI*2/7+x*.12+z*.15;
      const end=add(root,[Math.cos(angle)*.61,.62+.61*Math.sin(j*1.21)**2,Math.sin(angle)*.61]);
      const stem=add(root,[0,.38,0]);
      const tint=j%2?[.54,.31,.38]:[.59,.40,.27];
      beam(land,root,stem,.073,tint,5,.046);
      beam(land,stem,end,.052,tint,5,.023);
      beam(land,scale(add(stem,end),.5),add(end,[0,-.20,.23]),.037,tint,5,.014);
    }
  }

  // The wreck follows the same section profile for the hull, ribs and deck.
  function hull(u,a){
    const width=(.23+.77*Math.pow(Math.max(0,Math.sin(u*Math.PI)),.56))*3.9;
    const lateral=Math.sin(a)*width;
    return [-15+(u-.5)*23,-16.4-3.3*Math.cos(a)+lateral*.22,-47+lateral];
  }
  const rim=Math.PI*.51;
  for(let i=0;i<18;i++){
    for(let j=0;j<12;j++){
      if((i>6&&i<10&&j>7&&j<11)||random()<.075)continue;
      const a=-rim+j*rim/6,b=a+rim/6;
      quad(land,hull(i/18,a),hull((i+1)/18,a),hull((i+1)/18,b),hull(i/18,b),scale(iron,range(.64,1.53)));
    }
    if(i%2===0)for(let j=0;j<12;j++){
      const a=-rim+j*rim/6;
      beam(land,hull(i/18,a),hull(i/18,a+rim/6),.14,iron);
    }
  }
  for(let i=0;i<14;i++){
    if(i>6&&i<10)continue;
    const a=i/14,b=(i+.84)/14;
    quad(land,hull(a,-rim),hull(a,rim),hull(b,rim),hull(b,-rim),scale(iron,range(.7,1.36)));
  }
  beam(land,[-18,-17,-47],[-19,-7.5,-49],.24,iron,8,.13);
  beam(land,[-19,-10,-48.4],[-19,-11.2,-52.6],.15,iron,6,.08);
  beam(land,[-8,-17,-47],[-9,-11,-46],.19,iron,7,.07);

  quad(surface,[-145,0,-145],[145,0,-145],[145,0,145],[-145,0,145],[1,1,1]);
  for(let i=0;i<1900;i++)put(dust,[range(-65,65),range(-21,0),range(-97,42)],[0,1,0],[1,1,1]);
  function buffer(data){
    const item={buffer:gl.createBuffer(),count:data.length/9};
    gl.bindBuffer(gl.ARRAY_BUFFER,item.buffer);
    gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(data),gl.STATIC_DRAW);
    return item;
  }
  // Dress the routes in bands so the reef reads from the floor and from above.
  const reefBeds=[
    [0,1,8,10,62],[2,-15,10,8,49],[-5,-29,10,10,52],
    [-19,-42,12,9,46],[-24,-25,11,9,49],[17,-54,13,11,46],[-35,-56,14,12,43]
  ];
  function cup(x,y,z,r,h,tone,i){
    const rim=(j,rad,height)=>{
      const a=j*Math.PI*.25;
      return [x+Math.cos(a)*rad+height*.16,y+height*(1+.11*Math.sin(a*3+i)),z+Math.sin(a)*rad];
    };
    for(let j=0;j<8;j++){
      const a=rim(j,r,h),b=rim(j+1,r,h),c=rim(j+1,r*.65,h*.94),d=rim(j,r*.65,h*.94);
      quad(land,rim(j,r*.56,0),rim(j+1,r*.56,0),b,a,scale(tone,.77+j*.04));
      quad(land,a,b,c,d,scale(tone,1.21));
      tri(land,d,c,[x+h*.12,y+h*.46,z],scale(tone,.39));
    }
  }
  for(const [cx,cz,rx,rz,count] of reefBeds){
    for(let i=0;i<count;i++){
      const x=cx+range(-rx,rx),z=cz+range(-rz,rz),y=floor(x,z)+.09;
      if(inForum(x,z)&&Math.abs(x-forumX)<7.2&&Math.abs(z-forumZ)<7.3)continue;
      const color=scale(i%3===0?[.61,.41,.15]:i%3===1?[.50,.29,.34]:[.30,.49,.34],range(.7,1.3));
      const kind=i%5;
      if(kind===0){
        for(let j=0;j<4;j++)cup(x+range(-.57,.57),y,z+range(-.57,.57),range(.14,.34),range(.33,.91),color,j+i);
      }else if(kind===1||kind===2){
        const tips=kind===1?13:8;
        const stem=[x,y+.27,z], h=range(.42,1.32);
        for(let j=0;j<tips;j++){
          const a=j*2.399+i,r=range(.29,.72);
          const end=[x+Math.cos(a)*r,y+h*range(.60,1.17),z+Math.sin(a)*r];
          const mid=add(scale(add(stem,end),.5),[0,.13,0]);
          const axis=unit(sub(end,mid)),side=scale([-axis[2],0,axis[0]],kind===1?.15:.06);
          tri(land,stem,add(mid,side),mid,color);tri(land,stem,mid,sub(mid,side),color);
          tri(land,add(mid,side),end,mid,color);tri(land,mid,end,sub(mid,side),color);
        }
      }else if(kind===3){
        for(let j=0;j<9;j++){
          const a=j*2.399, r=.24+j*.051;
          const root=[x+Math.cos(a)*r,y,z+Math.sin(a)*r];
          const end=add(root,[Math.cos(a)*.34,range(.20,.53),Math.sin(a)*.34]);
          beam(land,root,end,.04,color,3,.011);
        }
      }else{
        const root=[x,y+.055,z], a=range(0,6.28), size=range(.16,.52);
        const edge=j=>[x+Math.cos(a+j*Math.PI/8)*size,y+.08+Math.sin(j*1.7)*.021,z+Math.sin(a+j*Math.PI/8)*size];
        const hinge=[x-Math.cos(a)*size*.57,y+.018,z-Math.sin(a)*size*.57];
        for(let j=-4;j<4;j++)tri(land,hinge,edge(j+1),edge(j),scale([.68,.48,.36],.72+(j%2===0?.23:0)));
        tri(land,root,edge(0),edge(3),[.45,.37,.27]);
      }
    }
  }

  const coins=[
    [-.8,-3,1.2],[-5,-13,1.5],[2,-24,1.1],[-4,-30,1.25],
    [-16,-40,1.5],[-21,-47,4.9],[gx-3,gz-3,1.42],[gx+4,gz-6,1.1],
    [17,-53,1.3],[24,-61,1.2],[forumX-6,forumZ+3.5,1.15],[forumX+1.8,forumZ-7.5,1.2]
  ].map(([x,z,h])=>{
    const offsets=[[0,0],[1.4,0],[-1.4,0],[0,1.4],[0,-1.4],[2.4,0],[-2.4,0],[0,2.4],[0,-2.4]];
    const candidates=[0,.75,1.65,2.9,4.5].flatMap(rise=>offsets.map(([dx,dz])=>[x+dx,floor(x+dx,z+dz)+h+rise,z+dz]));
    return candidates.find(point=>!rocks.some(({center,radii})=>{
      return Math.hypot(...sub(point,center).map((value,i)=>value/(radii[i]+.32)))<1;
    }))??candidates[0];
  });
  const coinMesh={buffer:gl.createBuffer(),count:0};
  const terrain=buffer(land), kelp=buffer(plants), water=buffer(surface), particles=buffer(dust), crystalsMesh=buffer(crystals);
  crystals.length=0;
  land=plants=surface=dust=null;
  const wildlife={buffer:gl.createBuffer(),count:0};
  const leviathan={buffer:gl.createBuffer(),count:0};
  let openingTime=null;
  function animateWhale(t,scene){
    const mesh=[];
    const phase=scene??((t+8)%66);
    const position=scene===null?[-phase*1.6+26,-7.7,-25]:[17-phase*3.75,-6.1+Math.sin(phase*.28)*.43,-5.8-phase*.36];
    const heading=scene===null?[-.94,0,-.34]:[-.985,0,-.17];
    const side=[-heading[2],0,heading[0]];
    const local=(length,width,height)=>add(position,add(add(scale(heading,length),scale(side,width)),[0,height,0]));
    const sections=[
      [-8.5,.13,.13],[-7.5,.28,.33],[-6.1,.53,.58],[-4.5,.86,1.06],
      [-2.4,1.47,1.36],[0,1.76,1.48],[2.05,1.65,1.35],
      [3.8,1.27,.92],[5.15,.74,.49],[5.9,.08,.11]
    ];
    const dark=[.108,.18,.22], pale=[.34,.43,.42];
    const bend=length=>Math.sin(t*1.26+length*.36)*Math.max(0,-length-1)*.14;
    const finBeat=Math.sin(t*1.26-2.8)*.69;
    const ring=(i,j)=>{
      const [z,w,h]=sections[i],a=j*Math.PI/12;
      return local(z,Math.sin(a)*w,Math.cos(a)*h+bend(z));
    };
    for(let i=0;i<sections.length-1;i++)for(let j=0;j<24;j++){
      const under=Math.max(0,-Math.cos((j+.5)*Math.PI/12));
      const tone=under>.39&&i>2?scale(pale,.72+under*.33):scale(dark,.81+.19*Math.sin(i*.75+j*.81)**2);
      quad(mesh,ring(i,j),ring(i,j+1),ring(i+1,j+1),ring(i+1,j),tone);
    }
    for(const dir of [-1,1]){
      const root=local(-8.1,0,bend(-8.1));
      const shoulder=local(-8.5,dir*1.42,bend(-8.5)+finBeat*.52);
      const tip=local(-10,dir*3.64,bend(-8.5)+finBeat);
      const notch=local(-9.65,dir*.35,bend(-8.5)-.13);
      const rear=local(-9.68,dir*1.64,bend(-8.5)+finBeat*.5);
      quad(mesh,root,shoulder,rear,notch,dark);
      tri(mesh,shoulder,tip,rear,scale(dark,1.22));
      const fin=local(1.75,dir*1.19,-.68), elbow=local(.61,dir*2.36,-.93+finBeat*.15);
      const outer=local(-1.66,dir*3.54,-1.45+finBeat*.43), trailing=local(.02,dir*1.32,-1.05);
      quad(mesh,fin,elbow,outer,trailing,scale(pale,.64));
      tri(mesh,fin,trailing,local(1.03,dir*1.68,-.65),dark);
    }
    tri(mesh,local(-3.9,0,1.16),local(-5.26,0,1.68),local(-5.75,0,.81),dark);
    upload(leviathan,mesh);
  }
  const schools=[
    {center:[-2,-11,-17],r:8,color:[.65,.71,.46]},
    {center:[8,-7,-28],r:9,color:[.39,.71,.74]},
    {center:[-16,-12,-43],r:11,color:[.74,.47,.26]},
    {center:[1,-5.1,-5],r:5,color:[.52,.71,.76],count:39,size:.59},
    {center:[3,-13,-28],r:6,color:[.74,.63,.35],count:25,size:.78},
    {center:[20,-15,-55],r:9,color:[.31,.65,.73],count:36,size:.74},
    {center:[-24,-9,-23],r:7,color:[.49,.64,.77],count:23,size:.68}
  ];
  for(const school of schools){
    school.fish=Array.from({length:school.count??31},()=>[
      range(-3.5,3.5),range(-1.6,1.6),range(-2.8,2.8),range(.3,.67)*(school.size??1)
    ]);
  }
  const glowLife={buffer:gl.createBuffer(),count:0};
  const bubbles={buffer:gl.createBuffer(),count:0};
  const arenaMesh={buffer:gl.createBuffer(),count:0};
  function upload(mesh,data){
    mesh.count=data.length/9;
    gl.bindBuffer(gl.ARRAY_BUFFER,mesh.buffer);
    gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(data),gl.DYNAMIC_DRAW);
  }

  // ReflexCore Citadel Combat Visual: native 3D character rigs, weapon poses,
  // muzzle flashes, animated projectiles and world-space health bars.
  // Reuses Akvarium's existing world meshes, materials, camera and GL draw pipeline.
  let arenaData=null;let lastRenderSignal=0,renderSequence=0;const arenaPalette={coral:[.95,.40,.61],kelp:[.13,.70,.57],amber:[1.,.68,.29],pearl:[.63,.96,1.]};
  function updateArena(data){
    if(!data||!Array.isArray(data.buildings)||!Array.isArray(data.units)||
       data.buildings.length>24||data.units.length>60||
       (data.projectiles&&(!Array.isArray(data.projectiles)||data.projectiles.length>160))||
       (data.effects&&(!Array.isArray(data.effects)||data.effects.length>95)))return;
    arenaData=data;
    const mesh=[];
    const numeric=(v,a,b)=>Number.isFinite(v)?Math.max(a,Math.min(b,v)):a;
    function position(item){
      const x=numeric(item.x,0,1024),z=numeric(item.y,0,640);
      return [forumX+(x/1024-.5)*21.8,forumY+.36,forumZ+(z/640-.5)*17.3];
    }
    function healthBar(x,y,z,w,ratio){
      const fraction=Math.max(0,Math.min(1,ratio));
      block(mesh,x,y,z,w,.095,.17,[.08,.14,.15]);
      if(fraction>.005)block(mesh,x-w*(1-fraction)*.5,y+.014,z+.014,w*fraction,.075,.19,
        fraction>.54?[.37,.98,.53]:fraction>.25?[1.,.75,.26]:[1.,.19,.20]);
    }
    // Heavy 3D arena set dressing: carved stone platforms, living branching coral,
    // lanterns and layered swaying seaweed. No third-party game models/assets.
    const waveTime=performance.now()*.001;
    const floorY=forumY+.42;
    for(let i=0;i<35;i++){
      const t=i*2.399963229728653,ring=.24+((i*71)%100)/100*.76;
      const x=forumX+Math.cos(t)*ring*10.9,z=forumZ+Math.sin(t)*ring*8.1;
      const height=.22+.12*Math.sin(i*1.7);
      block(mesh,x,floorY-height*.5,z,1.1+(i%3)*.3,height,.8+(i%4)*.24,[.24,.35,.38]);
      if(i%4===0){
        const coralColor=i%3===0?arenaPalette.coral:i%3===1?arenaPalette.pearl:arenaPalette.amber;
        beam(mesh,[x,floorY,z],[x,floorY+1.15,z],.14,coralColor,7,.07);
        for(let branch=0;branch<5;branch++){
          const theta=branch*1.26+i,span=.60+(branch%2)*.24;
          beam(mesh,[x,floorY+.56,z],[x+Math.cos(theta)*span,floorY+1.5,z+Math.sin(theta)*span],.085,scale(coralColor,.82),5,.02);
          beam(mesh,[x+Math.cos(theta)*span,floorY+1.5,z+Math.sin(theta)*span],
               [x+Math.cos(theta)*span*1.28,floorY+1.78,z+Math.sin(theta)*span*1.28],.047,coralColor,5,.005);
        }
      }else if(i%3===0){
        for(let strand=0;strand<5;strand++){
          const x0=x+Math.cos(strand*2)*.25,z0=z+Math.sin(strand*2)*.25,
                sway=Math.sin(waveTime*1.55+i+strand)*.27;
          beam(mesh,[x0,floorY,z0],[x0+sway*.5,floorY+.85,z0+sway*.2],.055,arenaPalette.kelp,5,.02);
          beam(mesh,[x0+sway*.5,floorY+.85,z0+sway*.2],[x0+sway,floorY+1.5,z0+sway*.45],.032,[.22,.83,.58],5,.01);
        }
      }
    }
    const colors={core:[.99,.29,.37],cannon:[.93,.59,.25],tower:[.47,.66,1.],wall:[.37,.60,.52]};
    for(const b of data.buildings){
      const color=colors[b.type];if(!color)continue;
      const [x,y,z]=position(b),hp=numeric(b.hp,0,10000),max=numeric(b.max,1,10000);
      const ratio=Math.max(0,Math.min(1,hp/max));
      if(hp<=0){
        for(let i=0;i<8;i++){const a=i*2.3999632,r=.6+(i%4)*.36;
          block(mesh,x+Math.cos(a)*r,y+.14+(i%2)*.15,z+Math.sin(a)*r,.45+(i%3)*.2,.30,.45,[.22,.27,.28]);}
        continue;
      }
      const h=b.type==='core'?4.2:b.type==='tower'?3.3:b.type==='cannon'?2.1:1.25;
      const hurt=numeric(b.hurt,0,1),flash=numeric(b.flash,0,1),tone=hurt>0?[1.,.91,.68]:color;
      block(mesh,x,y+.20,z,2.2,.40,2.2,[.19,.27,.31]);
      block(mesh,x,y+.58,z,1.65,.55,1.65,scale(tone,.49));
      for(let k=0;k<4;k++){
        const th=k*Math.PI/2+.785;
        block(mesh,x+Math.cos(th)*.93,y+.93,z+Math.sin(th)*.93,.26,.88,.25,[.18,.31,.32]);
        beam(mesh,[x+Math.cos(th)*1.18,y+.93,z+Math.sin(th)*1.18],
          [x+Math.cos(th)*1.18,y+1.6,z+Math.sin(th)*1.18],.075,scale(tone,.76),5,.01);
      }
      if(b.type==='wall'){
        block(mesh,x,y+1.02,z,2.5,.83,.78,tone);
        for(const dx of [-.9,-.3,.3,.9])block(mesh,x+dx,y+1.52,z,.44,.28,.85,scale(tone,.86));
      }else if(b.type==='cannon'){
        block(mesh,x,y+1.35,z,1.2,1.25,1.1,scale(tone,.76));
        const a=numeric(b.angle,-20,20),fx=Math.cos(a),fz=Math.sin(a);
        beam(mesh,[x,y+1.8,z],[x+fx*1.45,y+1.75,z+fz*1.15],.28,[.63,.71,.72],8,.2);
        if(flash>0){
          beam(mesh,[x+fx*1.45,y+1.75,z+fz*1.15],[x+fx*2.,y+1.75,z+fz*1.65],.37,[1.,.78,.27],6,.03);
          beam(mesh,[x+fx*1.45,y+1.75,z+fz*1.15],[x+fx*2.25,y+1.85,z+fz*1.8],.18,[1.,.96,.67],7,.04);
        }
      }else if(b.type==='tower'){
        block(mesh,x,y+1.63,z,1.05,2.0,1.05,scale(tone,.72));
        beam(mesh,[x,y+2.55,z],[x,y+3.7,z],.66,tone,5,.04);
        if(flash>0)beam(mesh,[x,y+3.55,z],[x,y+4.2,z],.45,[.9,1.,.96],6,.02);
      }else if(b.type==='core'){
        beam(mesh,[x,y+.65,z],[x,y+3.5,z],.9,[.72,.19,.33],8,.58);
        beam(mesh,[x,y+3.5,z],[x,y+4.65,z],.91,[1.,.42,.46],7,.08);
        for(let i=0;i<4;i++){
          const a=i*1.57+performance.now()*.00035;
          beam(mesh,[x+Math.cos(a)*1.35,y+1.45,z+Math.sin(a)*1.35],
            [x+Math.cos(a)*1.35,y+3.6,z+Math.sin(a)*1.35],.10,[1.,.35,.42],5,.05);
        }
      }
      healthBar(x,y+h+.78,z,Math.max(1.5,b.type==='core'?3.2:2.2),ratio);
    }
    const troopColors={giant:[.67,.90,.40],archer:[.25,.82,.68],sapper:[.98,.68,.32],raider:[.94,.40,.48],medic:[.65,.58,.99]};
    for(const u of data.units){
      const color=troopColors[u.type];if(!color)continue;
      const [x,y,z]=position(u),hp=numeric(u.hp,0,2000),max=numeric(u.max,1,2000);
      if(hp<=0)continue;
      const giant=u.type==='giant',h=giant?2.25:1.38,sc=giant?1.43:1;
      const ratio=Math.max(0,Math.min(1,hp/max)),pose=numeric(u.attackPose,0,1),walk=numeric(u.walk,0,100000);
      const hurt=numeric(u.hurt,0,1),tone=hurt>0?[1.,.93,.73]:color;
      const running=u.anim==='walk',bounce=running?Math.sin(walk)*.12:0;
      const a=numeric(u.heading,-20,20),dx=Math.cos(a),dz=Math.sin(a);
      const lateral=[-dz,dx];
      // Boots and stepping legs.
      for(const side of [-1,1]){
        const stride=running?Math.sin(walk+side*1.57)*.17:0;
        beam(mesh,[x+side*.20*sc,y+.09,z],[x+side*.20*sc+dx*stride,y+.62*sc,z+dz*stride],.13*sc,[.21,.26,.30],5,.10*sc);
      }
      block(mesh,x,y+.95*sc+bounce,z,.73*sc,.85*sc,.57*sc,scale(tone,.85));
      block(mesh,x,y+1.42*sc+bounce,z,.84*sc,.22*sc,.66*sc,scale(tone,.52));
      // Shoulder armour, belt buckle, twin luminous gauntlets and cloth cape.
      block(mesh,x,y+.74*sc+bounce,z,.78*sc,.13*sc,.61*sc,[.21,.27,.28]);
      block(mesh,x+dx*.36*sc,y+.96*sc+bounce,z+dz*.36*sc,.11*sc,.20*sc,.12*sc,[.85,.83,.63]);
      for(const shoulder of [-1,1]){
        const ax=x+lateral[0]*shoulder*.48*sc,az=z+lateral[1]*shoulder*.48*sc;
        block(mesh,ax,y+1.26*sc+bounce,az,.29*sc,.24*sc,.31*sc,[.28,.40,.43]);
        beam(mesh,[ax,y+1.32*sc+bounce,az],[ax,y+1.49*sc+bounce,az],.07*sc,scale(color,1.20),5,.01);
      }
      if(u.type==='raider'||u.type==='medic'){
        const tail=running?Math.sin(walk)*.13:Math.sin(waveTime*3+u.id)*.08;
        beam(mesh,[x-dx*.33,y+1.25,z-dz*.33],[x-dx*(.47+tail),y+.52,z-dz*(.47+tail)],.24,scale(color,.62),5,.10);
      }
      // Distinct head silhouettes and facial colors, not abstract colored sticks.
      beam(mesh,[x,y+1.47*sc+bounce,z],[x,y+1.85*sc+bounce,z],.30*sc,[.94,.73,.60],7,.26*sc);
      if(u.type==='archer'){
        beam(mesh,[x,y+1.73*sc,z],[x,y+2.04*sc,z],.38*sc,[.16,.43,.37],6,.13*sc);
        for(const i of [-1,0,1])beam(mesh,[x-dx*.12+i*.09,y+1.87,z-dz*.12],[x-dx*.23+i*.12,y+2.14,z-dz*.23],.06,[.92,.36,.55],5,.014);
      }else if(u.type==='sapper'){
        block(mesh,x,y+1.90*sc,z,.66*sc,.18*sc,.70*sc,[.74,.55,.30]);
        block(mesh,x-dx*.39,y+1.35,z-dz*.39,.37,.51,.4,[.28,.28,.31]);
      }else if(u.type==='raider'){
        beam(mesh,[x,y+1.8,z],[x+dx*.18,y+2.23,z+dz*.18],.29,[.32,.34,.43],6,.08);
      }else if(u.type==='medic'){
        block(mesh,x,y+1.05,z,.21,.68,.78,[.77,.88,.98]);
        block(mesh,x,y+1.05,z,.68,.20,.8,[.77,.88,.98]);
      }else{
        block(mesh,x,y+1.62*sc,z,.8*sc,.22*sc,.8*sc,[.68,.61,.37]);
      }
      const lift=pose*.55;
      for(const side of [-1,1]){
        const sx=x+lateral[0]*side*.41*sc,sz=z+lateral[1]*side*.41*sc;
        beam(mesh,[sx,y+1.22*sc+bounce,sz],
          [sx+dx*(.22+lift),y+(.88+lift)*sc+bounce,sz+dz*(.22+lift)],.12*sc,scale(tone,.72),5,.09*sc);
      }
      if(u.type==='giant'){
        const wx=x+dx*(.76+pose*.5),wz=z+dz*(.76+pose*.5);
        beam(mesh,[wx,y+1.5,z+dz*.76],[wx+dx*.42,y+1.15+pose,wz+dz*.42],.18,[.76,.61,.38],6,.15);
        block(mesh,wx+dx*.50,y+1.35+pose,wz+dz*.5,.75,.48,.74,[.60,.69,.68]);
      }else if(u.type==='archer'){
        const wx=x+dx*.66,wz=z+dz*.66;
        beam(mesh,[wx,y+.75,wz],[wx+dx*.12,y+1.75,wz+dz*.12],.045,[.83,.67,.36],5,.028);
        beam(mesh,[wx,y+1.75,wz],[wx+dx*.22,y+1.24,wz+dz*.22],.02,[.88,.94,.78],4,.012);
      }else if(u.type==='sapper'){
        block(mesh,x+dx*.65,y+1.18+pose*.26,z+dz*.65,.38,.38,.38,[1.,.73,.22]);
      }else if(u.type==='raider'){
        beam(mesh,[x+dx*.50,y+1.1,z+dz*.50],[x+dx*(1.05+pose*.3),y+1.47+pose*.6,z+dz*(1.05+pose*.3)],.09,[.87,.92,.94],5,.015);
      }else if(u.type==='medic'){
        beam(mesh,[x+dx*.68,y+.55,z+dz*.68],[x+dx*.65,y+2.1,z+dz*.65],.07,[.71,.61,.98],6,.055);
        beam(mesh,[x+dx*.65,y+2.1,z+dz*.65],[x+dx*.65,y+2.35+pose*.15,z+dz*.65],.22,[.55,1.,.87],6,.04);
      }
      // Underwater boot contact rings and damage flash.
      if(running){
        for(let ring=0;ring<5;ring++){
          const a=ring*Math.PI*2/5,r=.34+.05*Math.sin(walk);
          beam(mesh,[x+Math.cos(a)*r,y+.065,z+Math.sin(a)*r],
            [x+Math.cos(a+.7)*r,y+.065,z+Math.sin(a+.7)*r],.015,[.29,.70,.73],4,.005);
        }
      }
      if(hurt>0)beam(mesh,[x,y+.45,z],[x,y+1.96*sc,z],.07,[1.,.85,.55],6,.02);
      healthBar(x,y+h*1.42+.52,z,1.05*sc,ratio);
    }
    const projectileColors={arrow:[.98,.84,.48],bomb:[1.,.46,.22],cannon:[1.,.70,.24],bolt:[.68,.83,1.],heal:[.4,1.,.74]};
    for(const shot of (data.projectiles||[])){
      if(!projectileColors[shot.kind])continue;
      const [x,y,z]=position(shot),col=projectileColors[shot.kind];
      const rad=shot.kind==='bomb'?.3:shot.kind==='cannon'?.22:.12;
      beam(mesh,[x,y+.95,z],[x,y+1.2,z],rad,col,6,.04);
      if(shot.kind==='bomb'||shot.kind==='cannon')beam(mesh,[x,y+.9,z],[x,y+1.3,z],rad*1.32,[.98,.55,.25],6,.02);
    }
    // Shared targeting marker is world-space, not a fake browser cursor.
    const focus=data.buildings.find(b=>b.id===data.focusTargetId&&b.hp>0);
    if(focus){const [x,y,z]=position(focus),r=1.85+Math.sin(waveTime*4)*.14;
      for(let a=0;a<24;a++){
        const t=a*Math.PI/12,nt=(a+.5)*Math.PI/12;
        beam(mesh,[x+Math.cos(t)*r,y+.12,z+Math.sin(t)*r],
          [x+Math.cos(nt)*r,y+.12,z+Math.sin(nt)*r],.036,[1.,.9,.38],5,.01);
      }
      beam(mesh,[x,y+3.8,z],[x,y+5.3,z],.085,[1.,.94,.49],6,.016);
    }
    // The actual physics/HP transition produces each effect; never infer a hit from
    // renderer activity. Geometry expands and fades based on remaining effect life.
    for(const e of (data.effects||[])){
      if(!e||!['explosion','impact','heal','sonar','buff','deploy','muzzle','fall','target'].includes(e.kind))continue;
      const [x,y,z]=position(e),age=numeric(e.age,0,5),life=numeric(e.life,.01,5);
      const t=Math.min(1,age/life),amp=numeric(e.intensity,.2,3),rr=(.15+3.0*t)*amp;
      const col=e.kind==='explosion'?[1.,.55,.20]:e.kind==='heal'?[.35,1.,.68]:e.kind==='sonar'?[.19,.88,1.]:e.kind==='fall'?[.58,.58,.66]:[.96,.91,.55];
      for(let k=0;k<20;k++){
        const a=k*2*Math.PI/20,b=(k+1)*2*Math.PI/20;
        const yy=y+Math.sin(t*Math.PI)*(e.kind==='explosion'?1.15:.15);
        beam(mesh,[x+Math.cos(a)*rr,yy,z+Math.sin(a)*rr],
          [x+Math.cos(b)*rr,yy,z+Math.sin(b)*rr],(.035+.09*(1-t))*amp,scale(col,1.-t*.53),5,.006);
      }
      if(e.kind==='explosion'||e.kind==='muzzle'){
        for(let k=0;k<9;k++){
          const a=k*2.39996+age*3;
          beam(mesh,[x,y+.28,z],[x+Math.cos(a)*rr*.60,y+.45+(1-t)*1.4,z+Math.sin(a)*rr*.60],
            .05*(1-t)+.01,col,5,.01);
        }
      }
    }
    upload(arenaMesh,mesh);
  }
  window.addEventListener('message',event=>{
    if(event.source!==window.parent||event.origin!==location.origin)return;
    if(!event.data)return;
    if(event.data.type==='reflex-ocean-camera'){
      if(!Object.prototype.hasOwnProperty.call(arenaCameras,event.data.preset))return;
      arenaCamera=event.data.preset;reset();viewYaw=yaw;viewPitch=pitch;return;
    }
    if(event.data.type!=='reflex-citadel-scene')return;
    updateArena(event.data);
  });
  if(window.parent!==window&&location.origin!=='null')window.parent.postMessage({type:'reflex-ocean-ready'},location.origin);

  function animateExtras(t){
    const glow=[], plume=[];
    jellyOrigins.forEach((origin,i)=>{
      const p=add(origin,[Math.sin(t*.4+i)*.8,Math.sin(t*.62+i)*.8,Math.cos(t*.3+i)*.58]);
      const size=(.31+i%5*.085)*(1+.15*Math.sin(t*2+i));
      const ring=(j,a)=>{
        const arc=j*Math.PI/8;
        return add(p,[Math.cos(a)*Math.sin(arc)*size,Math.cos(arc)*size*.64,Math.sin(a)*Math.sin(arc)*size]);
      };
      const color=i%3?[.36,.63,.89]:[.74,.40,.81];
      for(let u=0;u<12;u++){
        const a=u*Math.PI/6,b=(u+1)*Math.PI/6;
        for(let j=0;j<4;j++)quad(glow,ring(j,a),ring(j+1,a),ring(j+1,b),ring(j,b),color);
        if(u%2===0){
          let point=ring(4,a);
          for(let j=1;j<=5;j++){
            const next=add(ring(4,a),[Math.sin(t*2+j*.72+u)*j*.026,-j*size*.35,Math.cos(t*1.6+j*.81+i)*j*.025]);
            beam(glow,point,next,.013,color,3,.009);
            point=next;
          }
        }
      }
    });
    chimneys.forEach(([x,y,z],i)=>{
      for(let j=0;j<24;j++){
        const h=(t*(.91+i%3*.13)+j*.58+i)%13;
        put(plume,[x+Math.sin(j*5.3+h*.76+i)*(.21+h*.095),y+h,z+Math.cos(j*3.8+h*.81)*(.21+h*.09)],[0,1,0],[1,1,1]);
      }
    });
    upload(glowLife,glow);upload(bubbles,plume);
  }
  function animateCoins(t){
    const mesh=[];
    coins.forEach(([x,y,z],i)=>{
      if(collected.has(i)||Math.hypot(x-eye[0],y-eye[1],z-eye[2])>46)return;
      const center=[x,y+.10*Math.sin(t*1.7+i),z], angle=t*.81+i*2.4;
      const right=[Math.cos(angle),0,Math.sin(angle)], axis=[-right[2],0,right[0]];
      const ring=(angle,r)=>add(scale(right,Math.cos(angle)*r),[0,Math.sin(angle)*r,0]);
      for(const sign of [-1,1]){
        const face=add(center,scale(axis,sign*.045));
        for(let j=0;j<12;j++){
          const a=j*Math.PI/6,b=a+Math.PI/6;
          const v=r=>add(face,ring(r,.262)), inset=r=>add(face,ring(r,.205));
          const gold=j%3===0?[.93,.59,.19]:[.64,.38,.105];
          quad(mesh,v(a),v(b),inset(b),inset(a),gold);
          tri(mesh,face,inset(a),inset(b),[.31,.176,.052]);
          const gleam=add(face,ring(a,.125));
          tri(mesh,gleam,add(face,ring(a+.16,.074)),add(face,ring(a-.16,.074)),[.9,.54,.14]);
          if(sign===1){
            const back=scale(axis,-.09);
            quad(mesh,v(b),v(a),add(v(a),back),add(v(b),back),[.76,.45,.12]);
          }
        }
      }
    });
    upload(coinMesh,mesh);
  }
  function animateLife(t){
    const mesh=[];
    for(const [index,school] of schools.entries()){
      const a=t*(.15+index*.011)+index*2.5;
      const dir=[Math.cos(a),0,-Math.sin(a)], side=[-dir[2],0,dir[0]];
      const center=add(school.center,[Math.sin(a)*school.r,Math.sin(a*1.4),Math.cos(a)*school.r*.6]);
      for(const [u,v,w,s] of school.fish){
        const p=add(center,add(scale(dir,u),add(scale(side,w),[0,v+.15*Math.sin(t*3+u),0])));
        const head=add(p,scale(dir,s));
        const back=add(p,scale(dir,-s*.67));
        const top=add(p,[0,s*.3,0]), bottom=add(p,[0,-s*.26,0]);
        const flank=add(p,scale(side,s*.2)), other=add(p,scale(side,-s*.2));
        for(const cheek of [flank,other]){
          tri(mesh,head,top,cheek,school.color);tri(mesh,head,cheek,bottom,school.color);
          tri(mesh,back,cheek,top,school.color);tri(mesh,back,bottom,cheek,school.color);
        }
        const tail=add(back,add(scale(dir,-s*.52),scale(side,Math.sin(t*11+u)*s*.27)));
        tri(mesh,back,add(tail,[0,s*.29,0]),add(tail,[0,-s*.29,0]),school.color);
      }
    }
    for(let i=0;i<2;i++){
      const a=t*.125+i*2.7, p=[Math.sin(a)*15-3,-7+i*2+Math.sin(a*.8),-24+Math.cos(a)*10];
      const f=[Math.cos(a),0,-Math.sin(a)*.67], side=unit([-f[2],0,f[0]]);
      const nose=add(p,scale(f,1.25)), tail=add(p,scale(f,-1.1)), crown=add(p,[0,.24,0]);
      const color=[.21,.31,.37];
      for(const sign of [-1,1]){
        const wing=add(add(p,scale(side,sign*3.5)),add(scale(f,-.91),[0,Math.sin(t*2+i)*.53,0]));
        const mid=add(add(p,scale(side,sign*1.62)),add(scale(f,.38),[0,Math.sin(t*2+i)*.24,0]));
        tri(mesh,nose,mid,crown,color);tri(mesh,mid,wing,tail,color);tri(mesh,mid,tail,crown,color);
        tri(mesh,nose,wing,mid,[.35,.43,.43]);
      }
      beam(mesh,tail,add(tail,scale(f,-1.85)),.065,color,5,.013);
    }
    for(const [cx,cy,cz,phase] of [[2,-7,-15,.6],[17,-11,-44,2.7],[-16,-8,-37,4.1]]){
      const a=t*.089+phase;
      const f=[Math.cos(a),0,-Math.sin(a)],side=[-f[2],0,f[0]];
      const p=[cx+Math.sin(a)*5.6,cy+Math.sin(a*1.2)*.85,cz+Math.cos(a)*5.6];
      const shell=[.36,.46,.29], skin=[.27,.42,.32], belly=[.52,.53,.34];
      const local=(x,y,z)=>add(p,add(add(scale(side,x),scale(f,z)),[0,y,0]));
      const rim=(ring,i)=>{
        const theta=i*Math.PI/6;
        const r=[1,.92,.54,0][ring];
        return local(Math.sin(theta)*.7*r,[-.19,.04,.39,.49][ring],Math.cos(theta)*.99*r);
      };
      for(let i=0;i<12;i++){
        for(let j=0;j<3;j++){
          quad(mesh,rim(j,i),rim(j,i+1),rim(j+1,i+1),rim(j+1,i),scale(shell,.82+(i%3)*.1));
        }
        tri(mesh,local(0,-.24,0),rim(0,i+1),rim(0,i),belly);
      }
      beam(mesh,local(0,-.09,.77),local(0,-.02,1.27),.16,skin,8,.13);
      beam(mesh,local(0,-.02,1.24),local(0,-.035,1.44),.17,skin,8,.065);
      for(const sign of [-1,1]){
        const sweep=Math.sin(t*1.55+phase)*.35;
        quad(mesh,local(sign*.51,-.07,.52),local(sign*.92,sweep,.54),
          local(sign*1.35,sweep*1.45,-.02),local(sign*.59,-.12,.13),skin);
        tri(mesh,local(sign*.41,-.11,-.62),local(sign*.91,sweep*.54,-.96),local(sign*.37,-.11,-.92),skin);
      }
    }
    upload(wildlife,mesh);
  }
  function draw(item,primitive,mode,sway=0){
    gl.uniform1f(uniforms.mode,mode);gl.uniform1f(uniforms.sway,sway);
    gl.bindBuffer(gl.ARRAY_BUFFER,item.buffer);
    attributes.forEach((index,i)=>gl.vertexAttribPointer(index,3,gl.FLOAT,false,36,i*12));
    gl.drawArrays(primitive,0,item.count);
  }

  if(hasShadows){
    gl.bindFramebuffer(gl.FRAMEBUFFER,shadowTarget);
    gl.viewport(0,0,shadowSize,shadowSize);
    gl.disable(gl.DITHER);
    gl.enable(gl.POLYGON_OFFSET_FILL);
    gl.polygonOffset(1.,2.);
    gl.clearColor(1,1,1,1);
    gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
    draw(terrain,gl.TRIANGLES,3);
    draw(kelp,gl.TRIANGLES,3);
    gl.disable(gl.POLYGON_OFFSET_FILL);
    gl.enable(gl.DITHER);
    gl.bindFramebuffer(gl.FRAMEBUFFER,null);
    gl.bindTexture(gl.TEXTURE_2D,shadowMap);
  }

  const keys=new Set();
  const controls=['KeyW','KeyA','KeyS','KeyD','ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Space','KeyC','ShiftLeft','ShiftRight'];
  let eye,velocity,yaw,pitch,drag=null,mouse=null;
  // 3D Citadel camera: near = default, close = troops, overview = original distant view.
  const arenaCameras={
    near:{eye:[forumX,-9.8,forumZ+13.5],pitch:-.68},
    close:{eye:[forumX,-11.4,forumZ+10.9],pitch:-.76},
    overview:{eye:[forumX,-5.9,forumZ+29],pitch:-.43}
  };
  let arenaCamera='near';
  function reset(){
    const view=arenaCameras[arenaCamera];
    eye=arenaMode?view.eye.slice():[0,-10,9];velocity=[0,0,0];yaw=arenaMode?0:-.09;
    pitch=arenaMode?view.pitch:-.21;mouse=null;
  }
  const fullscreenButton=document.querySelector('#fullscreen');
  async function toggleFullscreen(){
    try{
      if(document.fullscreenElement)await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
    }catch{
      fullscreenButton.title='The browser blocked fullscreen';
    }
  }
  fullscreenButton.addEventListener('click',toggleFullscreen);
  document.addEventListener('fullscreenchange',()=>{
    mouse=null;
    fullscreenButton.setAttribute('aria-pressed',String(Boolean(document.fullscreenElement)));
  });
  reset();
  const destination=document.querySelector('#destination');
  const dives={
    kelp:{name:'Kelp Forest',position:[-2,-11,-6],heading:.22,center:[1,-10],radius:9},
    tail:{name:'Stone Fluke',position:[1,-13,-23],heading:.09,center:[tailX,tailZ],radius:13},
    wreck:{name:'Shipwreck',position:[-15,-11,-38],heading:0,center:[-15,-47],radius:14},
    grotto:{name:'Jellyfish Grotto',position:[gx,-14,gz+11],heading:0,center:grotto,radius:12},
    vents:{name:'Vent Field',position:[vents[0],-17,vents[1]+11],heading:0,center:vents,radius:13},
    forum:{name:'Sunken Forum',position:[forumX,-16.8,forumZ+9.8],heading:0,center:forum,radius:12}
  };
  const landmarks=Object.values(dives);
  const visited=new Set();
  const coinReadout=document.querySelector('#coins'),coinNote=document.querySelector('#coin-note');
  const coinStorageSlot='quiet-depths-coins-v1';
  const collected=new Set();
  try{
    const saved=JSON.parse(localStorage.getItem(coinStorageSlot)??'[]');
    if(Array.isArray(saved))for(const index of saved){
      if(Number.isInteger(index)&&index>=0&&index<coins.length)collected.add(index);
    }
  }catch{}
  let noteUntil=0;
  function displayCoins(){
    coinReadout.textContent=collected.size+' found · '+(coins.length-collected.size)+' left';
  }
  displayCoins();
  function checkCoins(t){
    for(const [i,position] of coins.entries()){
      if(collected.has(i)||Math.hypot(...sub(position,eye))>1.24)continue;
      collected.add(i);
      displayCoins();
      coinNote.textContent=collected.size===coins.length?'All coins recovered':'Coin recovered';
      coinNote.hidden=false;
      noteUntil=t+2.35;
      try{localStorage.setItem(coinStorageSlot,JSON.stringify([...collected]));}catch{}
    }
    if(t>=noteUntil)coinNote.hidden=true;
  }
  const lampButton=document.querySelector('#lamp');
  const stopFilm=document.querySelector('#stop-film');
  const cut=document.querySelector('#cut');
  let lampOn=false,pulse=null,filmClock=0,filmActive=false;
  const entryFade=.42;
  const cinemaButton=document.querySelector('#cinema');
  let cinemaOn=false,viewYaw=yaw,viewPitch=pitch,lens=1.56;
  function cinemaToggle(){
    cinemaOn=!cinemaOn;
    cinemaButton.setAttribute('aria-pressed',String(cinemaOn));
    document.body.classList.toggle('cinema',cinemaOn);
  }
  cinemaButton.addEventListener('click',cinemaToggle);
  const shots=[
    openingShot,
    {from:[1,-12,-20],to:[4,-13,-25],aim:[2,-14,-32]},
    {from:[gx,-13.6,gz+11],to:[gx+.8,-14.5,gz+4],aim:[gx,gy+4.7,gz-7]},
    {from:[-15,-10.4,-37],to:[-12,-10,-42],aim:[-15,-15,-47]},
    {from:[20,-16,-49],to:[17,-17,-54],aim:[21,-19,-63]},
    {from:[forumX,-16,forumZ+9.8],to:[forumX+1,-17.9,forumZ+2.5],aim:[forumX,-17.4,forumZ-7],seconds:10}
  ];
  function lampToggle(){
    lampOn=!lampOn;
    lampButton.setAttribute('aria-pressed',String(lampOn));
  }
  function sonarPing(){pulse={origin:eye.slice(),time:performance.now()*.001};}
  function filmToggle(){
    filmActive=!filmActive;
    filmClock=-entryFade;
    openingTime=null;
    yaw=viewYaw;
    pitch=viewPitch;
    keys.clear();
    velocity=[0,0,0];
    mouse=null;
    document.body.classList.toggle('film',filmActive);
    stopFilm.hidden=!filmActive;
    cut.style.opacity='0';
    if(filmActive&&document.pointerLockElement===canvas)document.exitPointerLock();
  }
  lampButton.addEventListener('click',lampToggle);
  document.querySelector('#sonar').addEventListener('click',sonarPing);
  document.querySelector('#film').addEventListener('click',filmToggle);
  stopFilm.addEventListener('click',filmToggle);
  const filmLength=shots.reduce((total,shot)=>total+(shot.seconds??8),0);
  function smoothStep(x){
    const u=Math.max(0,Math.min(1,x));
    return u*u*(3-2*u);
  }
  function filmCamera(dt){
    filmClock+=dt;
    if(filmClock<0){
      cut.style.opacity=String(smoothStep(1+filmClock/entryFade));
      return;
    }
    let elapsed=filmClock%filmLength;
    let shot=shots[0];
    for(const candidate of shots){
      shot=candidate;
      if(elapsed<(shot.seconds??8))break;
      elapsed-=shot.seconds??8;
    }
    const phase=elapsed/(shot.seconds??8);
    const smooth=smoothStep(phase);
    eye=add(shot.from,scale(sub(shot.to,shot.from),smooth));
    openingTime=shot===openingShot?elapsed:null;
    const focus=shot===openingShot?(()=>{
      const tilt=smoothStep((elapsed-1.55)/4.2);
      const lead=3.2-7.4*smoothStep((elapsed-3.0)/5.5);
      return add(shot.aim,scale(sub([lead,-6.6,-10.2],shot.aim),tilt));
    })():shot.aim;
    const look=sub(focus,eye);
    yaw=Math.atan2(look[0],-look[2]);
    pitch=Math.atan2(look[1],Math.hypot(look[0],look[2]));
    const fadeIn=smoothStep(elapsed/(shot===openingShot ? .60 : .78));
    const fadeOut=smoothStep(((shot.seconds??8)-elapsed)/.74);
    cut.style.opacity=String(1-fadeIn*fadeOut);
  }
  const survey=document.querySelector('#survey');
  destination.addEventListener('change',()=>{
    const dive=dives[destination.value];
    if(!dive)return;
    eye=dive.position.slice();
    velocity=[0,0,0];
    yaw=viewYaw=dive.heading;
    pitch=viewPitch=-.16;
    mouse=null;
    keys.clear();
    destination.value='';
    destination.blur();
  });
  document.querySelector('#reset').addEventListener('click',()=>{reset();viewYaw=yaw;viewPitch=pitch;});
  addEventListener('keydown',event=>{
    if(arenaMode||event.ctrlKey||event.altKey||event.metaKey)return;
    if(event.code==='KeyV'||(filmActive&&event.code==='Escape')){
      if(!event.repeat)filmToggle();
      return;
    }
    if(event.code==='KeyM'){
      if(!event.repeat)cinemaToggle();
      return;
    }
    if(event.code==='KeyL'||event.code==='KeyQ'){
      if(!event.repeat){
        if(event.code==='KeyL')lampToggle();
        else sonarPing();
      }
      return;
    }
    if(event.code==='KeyH'&&!event.repeat){
      document.body.classList.toggle('photo');
      return;
    }
    if(event.code==='KeyF'){
      event.preventDefault();
      if(!event.repeat)toggleFullscreen();
      return;
    }
    if(filmActive||event.target instanceof HTMLSelectElement||!controls.includes(event.code)||event.target instanceof HTMLButtonElement&&event.code==='Space')return;
    event.preventDefault();keys.add(event.code);
  });
  addEventListener('keyup',event=>keys.delete(event.code));
  addEventListener('blur',()=>{keys.clear();drag=null;mouse=null;});
  canvas.addEventListener('contextmenu',event=>event.preventDefault());
  // Listen for mouse buttons individually, even while another button is held.
  canvas.addEventListener('mousedown',event=>{
    if(event.button===2&&document.pointerLockElement===canvas){
      event.preventDefault();
      document.exitPointerLock();
    }
  });
  canvas.addEventListener('pointerdown',event=>{
    if(arenaMode||filmActive)return;
    if(event.pointerType==='mouse'){
      if(event.button!==0||document.pointerLockElement===canvas)return;
      try{
        const lock=canvas.requestPointerLock?.();
        lock?.catch(()=>{});
      }catch{}
      return;
    }
    if(drag)return;
    drag={id:event.pointerId,x:event.clientX,y:event.clientY};
    canvas.setPointerCapture(drag.id);
  });
  function look(dx,dy){
    if(arenaMode||filmActive)return;
    yaw+=dx*.0035;
    pitch=Math.max(-1.43,Math.min(1.43,pitch-dy*.0035));
  }
  canvas.addEventListener('pointermove',event=>{
    if(event.pointerType==='mouse'){
      if(document.pointerLockElement===canvas){
        look(event.movementX,event.movementY);
      }else{
        if(mouse)look(event.clientX-mouse.x,event.clientY-mouse.y);
        mouse={x:event.clientX,y:event.clientY};
      }
      return;
    }
    if(drag?.id!==event.pointerId)return;
    look(event.clientX-drag.x,event.clientY-drag.y);
    drag.x=event.clientX;
    drag.y=event.clientY;
  });
  canvas.addEventListener('pointerleave',()=>{mouse=null;});
  document.addEventListener('pointerlockchange',()=>{mouse=null;});
  canvas.addEventListener('lostpointercapture',event=>{if(drag?.id===event.pointerId)drag=null;});
  document.querySelectorAll('[data-move]').forEach(button=>{
    button.addEventListener('pointerdown',event=>{button.setPointerCapture(event.pointerId);keys.add(button.dataset.move);});
    for(const type of ['pointerup','pointercancel','lostpointercapture'])button.addEventListener(type,()=>keys.delete(button.dataset.move));
  });
  const locationText=document.querySelector('#location'), depth=document.querySelector('#depth');
  let previous=0, lastWildlife=-1;
  function frame(now){
    const t=now*.001,frameTime=t-(previous||t);
    const dt=Math.min(.042,frameTime);
    previous=t;
    if(!arenaMode&&filmActive)filmCamera(Math.min(.064,frameTime));
    else openingTime=null;
    const ease=cinemaOn&&!filmActive?1-Math.exp(-dt*5.1):1;
    viewYaw+=(yaw-viewYaw)*ease;
    viewPitch+=(pitch-viewPitch)*ease;
    const f=[Math.sin(viewYaw)*Math.cos(viewPitch),Math.sin(viewPitch),-Math.cos(viewYaw)*Math.cos(viewPitch)];
    const r=[Math.cos(viewYaw),0,Math.sin(viewYaw)],u=cross(r,f);
    if(!arenaMode&&!filmActive){
      const movement=[
        (keys.has('KeyW')||keys.has('ArrowUp'))-(keys.has('KeyS')||keys.has('ArrowDown')),
        (keys.has('KeyD')||keys.has('ArrowRight'))-(keys.has('KeyA')||keys.has('ArrowLeft')),
        keys.has('Space')-keys.has('KeyC')
      ];
      const speed=keys.has('ShiftLeft')||keys.has('ShiftRight')?6.1:2.65;
      const vector=add(add(scale(f,movement[0]),scale(r,movement[1])),[0,movement[2],0]);
      const thrust=scale(unit(vector),speed);
      thrust[1]*=.76;
      const current=[Math.sin(t*.22+eye[2]*.10)*.13,Math.sin(t*.31+eye[0]*.12)*.046,Math.cos(t*.19+eye[0]*.10)*.10];
      const goal=add(thrust,current);
      const stroking=movement.some(Boolean);
      velocity=velocity.map((value,i)=>{
        const drag=i===1?1.65:stroking?1.42:1.20;
        return value+(goal[i]-value)*(1-Math.exp(-dt*drag));
      });
      const target=add(eye,scale(velocity,dt));
      for(const {center,radii} of rocks){
        const offset=sub(target,center);
        const q=offset.map((value,i)=>value/radii[i]);
        const distance=Math.hypot(...q);
        if(distance>=1||distance<.0001)continue;
        const normal=unit(q.map((value,i)=>value/radii[i]));
        for(let i=0;i<3;i++)target[i]=center[i]+offset[i]/distance;
        const inward=velocity.reduce((sum,value,i)=>sum+value*normal[i],0);
        if(inward<0)velocity=sub(velocity,scale(normal,inward));
      }
      const limits=[[-70,70],[0,-.8],[-90,36]];
      for(const i of [0,2,1]){
        const [low,high]=i===1?[floor(target[0],target[2])+.85,-.8]:limits[i];
        const bounded=Math.min(high,Math.max(low,target[i]));
        if(bounded!==target[i])velocity[i]=0;
        target[i]=bounded;
      }
      eye=target;
    }
    let landmark=null,nearest=Infinity;
    for(const site of landmarks){
      const distance=Math.hypot(eye[0]-site.center[0],eye[2]-site.center[1]);
      if(distance>=site.radius||distance>=nearest)continue;
      landmark=site;
      nearest=distance;
    }
    if(!arenaMode&&!filmActive){
      if(landmark)visited.add(landmark.name);
      checkCoins(t);
    }
    const zone=landmark?.name??'Turquoise Canyon';
    if(locationText.textContent!==zone)locationText.textContent=zone;
    const count=visited.size+' / '+landmarks.length+' sites';
    if(survey.textContent!==count)survey.textContent=count;
    const depthLabel=Math.round(-eye[1])+' m';
    if(depth.textContent!==depthLabel)depth.textContent=depthLabel;
    const ratio=Math.min(devicePixelRatio,1.5,1700/Math.max(canvas.clientWidth,1));
    const width=Math.max(1,Math.round(canvas.clientWidth*ratio)),height=Math.max(1,Math.round(canvas.clientHeight*ratio));
    if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}
    gl.viewport(0,0,width,height);
    gl.clearColor(.028,.207,.273,1);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
    const breathing=filmActive||cinemaOn?0:Math.sin(t*1.05)*.023+Math.sin(t*.58)*.017;
    gl.uniform3fv(uniforms.eye,[eye[0],eye[1]+breathing,eye[2]]);gl.uniform3fv(uniforms.forward,f);
    gl.uniform3fv(uniforms.right,r);gl.uniform3fv(uniforms.up,u);
    gl.uniform1f(uniforms.lamp,lampOn?1:0);
    if(pulse&&t-pulse.time>3.6)pulse=null;
    const [px,py,pz]=pulse?.origin??eye;
    gl.uniform4f(uniforms.ping,px,py,pz,pulse?Math.max(0,t-pulse.time)*15:-1);
    lens+=((cinemaOn||filmActive?1.71:1.56)-lens)*(1-Math.exp(-dt*3.2));
    gl.uniform2f(uniforms.lens,Math.min(2.25,lens*height/width),lens);gl.uniform1f(uniforms.time,t%10000);
    draw(water,gl.TRIANGLES,1);draw(terrain,gl.TRIANGLES,0);draw(kelp,gl.TRIANGLES,5,1);draw(arenaMesh,gl.TRIANGLES,6);
    if(t-lastWildlife>.05){animateLife(t);animateExtras(t);animateCoins(t);lastWildlife=t;}
    draw(wildlife,gl.TRIANGLES,8);
    if(!filmActive||openingTime!==null){
      animateWhale(t,openingTime);
      draw(leviathan,gl.TRIANGLES,9);
    }
    draw(coinMesh,gl.TRIANGLES,6);
    draw(crystalsMesh,gl.TRIANGLES,6);draw(glowLife,gl.TRIANGLES,6);
    gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE);gl.depthMask(false);
    draw(particles,gl.POINTS,2,.33);draw(bubbles,gl.POINTS,2);
    gl.depthMask(true);gl.disable(gl.BLEND);
    // Only report a rendered frame AFTER submitting GL draw calls.
    // This is liveness evidence, not proof of what a human sees on the monitor.
    if(arenaData&&window.parent!==window&&location.origin!=='null'&&now-lastRenderSignal>750){
      lastRenderSignal=now;
      try{window.parent.postMessage({type:'reflex-ocean-rendered',sequence:++renderSequence,
        unit_count:arenaData.units.length,building_count:arenaData.buildings.length},location.origin);}catch{}
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}
