// Transpose check (26 Oct 2026): does playback follow the ♭/♯ buttons?
// abcjs plays visualTranspose at the WRITTEN pitch; abc.html adds midiTranspose
// to put the shift back. Run: node _tp.js — the third line should be 2 higher.
const fs=require("fs"),{JSDOM}=require(process.cwd()+"/node_modules/jsdom");
const src=fs.readFileSync("../../Sources/CeolCore/Web/abcjs-basic-min.js","utf8");
function pitches(vt, mt){
  const dom=new JSDOM('<div id="p"></div>',{pretendToBeVisual:true});
  new Function("window","document","navigator",src).call(dom.window,dom.window,dom.window.document,dom.window.navigator);
  const A=dom.window.ABCJS;
  const t=A.renderAbc("p","X:1\nL:1/4\nK:D\nDEFG|",vt?{visualTranspose:vt}:{})[0];
  const opts={}; if(mt) opts.midiTranspose=mt;
  const a=t.setUpAudio(opts);
  return a.tracks.flat().filter(e=>e.cmd==="note").map(e=>e.pitch).slice(0,4).join(",");
}
console.log("written           ", pitches(0,0));
console.log("visual +2 only    ", pitches(2,0));
console.log("visual +2, midi +2", pitches(2,2));
