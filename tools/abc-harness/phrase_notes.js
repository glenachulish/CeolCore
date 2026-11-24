// FONN-LAYOUT-2: node phrase_notes.js pairs.json  (pairs from tools/verify_abcphrase.py)
// Every note, pitch and duration must come out the same after phrasing.
const fs=require("fs"),path=require("path");
const H=__dirname;
const {JSDOM}=require(H+"/node_modules/jsdom");
const dom=new JSDOM("<!DOCTYPE html><div id=p></div>");
global.window=dom.window;global.document=dom.window.document;global.navigator=dom.window.navigator;
const src=fs.readFileSync(__dirname+"/../../Sources/CeolCore/Web/abcjs-basic-min.js","utf8");
const ABCJS=(new Function("window","document","navigator",src+";return window.ABCJS||ABCJS;"))(window,document,navigator);
function seq(abc){const t=ABCJS.parseOnly(abc)[0];const out=[];let lines=0;
 (t.lines||[]).forEach(l=>{if(!l.staff)return;lines++;l.staff.forEach(s=>s.voices.forEach(v=>v.forEach(e=>{if(e.el_type==="note")out.push((e.pitches||[]).map(p=>p.pitch+(p.accidental||"")).join(",")+"/"+e.duration+(e.rest?"r":""));else if(e.el_type==="bar"&&process.env.BARS)out.push((e.type.indexOf("repeat")>=0?e.type:"")+(e.startEnding||"")+(e.endEnding?"E":""));})))});
 return {s:out.join(" "),lines};}
const pairs=JSON.parse(fs.readFileSync(process.argv[2]||"pairs.json"));let bad=0,n=0;
for(const [t,a,b] of pairs){n++;let x,y;try{x=seq(a);y=seq(b);}catch(e){console.log("ERR",t,e.message);continue}
 if(x.s!==y.s){bad++;if(bad<=8){console.log("DIFF",t);const xa=x.s.split(" "),ya=y.s.split(" ");let i=0;while(xa[i]===ya[i])i++;console.log("  was:",xa.slice(i,i+6).join(" "));console.log("  now:",ya.slice(i,i+6).join(" "));}}}
console.log("checked",n,"differ",bad);
