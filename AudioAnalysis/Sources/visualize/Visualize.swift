import Foundation
import AudioAnalysis

/// Command-line tool: fetches one or more song previews, runs the full
/// analysis pipeline on each, and writes a single self-contained HTML
/// visualization with a song switcher.
///
/// Usage:  swift run visualize "Song One Artist" "Song Two Artist" ...
///         swift run visualize            (uses a built-in default set)
@main
struct Visualize {

    /// A feature frame flattened for JSON export to the browser.
    struct ExportFrame: Encodable {
        let t: Double   // time (s)
        let h: Double   // tonal color hue
        let s: Double   // tonal color saturation (chromagram peakedness)
        let b: Double   // tonal color brightness
        let tb: Double  // timbre brightness
        let l: Double   // loudness (RMS)
        let hc: Double  // harmonic complexity
        let o: Bool     // onset on this frame
    }

    /// One analyzed song, ready to embed in the page.
    struct SongExport: Encodable {
        let title: String
        let artist: String
        let audio: String          // an audio/mp4 data URI
        let bpm: Double
        let tempoConfidence: Double
        let frames: [ExportFrame]
    }

    static let defaultSongs = [
        "Get Lucky Daft Punk",
        "Bohemian Rhapsody Queen",
        "Smells Like Teen Spirit Nirvana",
        "Billie Jean Michael Jackson",
        "Clair de Lune Debussy",
        "Shadowplay Joy Division",
        "Comfortably Numb Pink Floyd",
    ]

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let searchTerms = args.isEmpty ? defaultSongs : args

        var songs: [SongExport] = []
        for term in searchTerms {
            do {
                print("Fetching \"\(term)\"...")
                let results = try await PreviewFetcher.search(term, limit: 5)
                guard let song = results.first else {
                    print("  no results — skipping")
                    continue
                }

                let fileURL = try await PreviewFetcher.downloadPreview(from: song.previewURL)
                defer { try? FileManager.default.removeItem(at: fileURL) }

                let audioData = try Data(contentsOf: fileURL)
                let audio = try AudioFileDecoder.decode(contentsOf: fileURL)
                let frames = AnalysisTimeline.analyze(audio).map { frame in
                    ExportFrame(
                        t: frame.time,
                        h: frame.color.hue,
                        s: frame.color.saturation,
                        b: frame.color.brightness,
                        tb: Double(frame.timbreBrightness),
                        l: Double(frame.loudness),
                        hc: Double(frame.harmonicComplexity),
                        o: frame.onset
                    )
                }
                let tempo = TempoDetector.detect(in: audio)
                songs.append(SongExport(
                    title: song.trackName,
                    artist: song.artistName,
                    audio: "data:audio/mp4;base64," + audioData.base64EncodedString(),
                    bpm: tempo?.bpm ?? 0,
                    tempoConfidence: Double(tempo?.confidence ?? 0),
                    frames: frames
                ))
                print("  \(song.trackName) — \(song.artistName): \(frames.count) frames")
            } catch {
                print("  error: \(error)")
            }
        }

        guard !songs.isEmpty else {
            print("No songs could be analyzed.")
            exit(1)
        }

        do {
            let songsJSON = String(decoding: try JSONEncoder().encode(songs), as: UTF8.self)
            let html = makeHTML(songsJSON: songsJSON)
            let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("visualization.html")
            try html.write(to: outputURL, atomically: true, encoding: .utf8)
            print("Wrote \(outputURL.path) — \(songs.count) song(s)")
        } catch {
            print("Error writing output: \(error)")
            exit(1)
        }
    }

    static func makeHTML(songsJSON: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>AVP Visualizer — 3D</title>
        <style>
          html,body{margin:0;height:100%;background:#070709;overflow:hidden;
            font-family:-apple-system,system-ui,sans-serif;}
          #webgl{position:fixed;inset:0;z-index:0;}
          #grain{position:fixed;inset:0;z-index:1;pointer-events:none;
            mix-blend-mode:overlay;}
          #songs{position:fixed;top:0;left:0;right:0;display:flex;gap:6px;
            padding:10px;justify-content:center;flex-wrap:wrap;z-index:10;}
          #songs button{background:rgba(255,255,255,0.1);color:rgba(255,255,255,0.7);
            border:1px solid rgba(255,255,255,0.18);border-radius:14px;padding:6px 14px;
            font:12px/1 -apple-system,system-ui,sans-serif;cursor:pointer;transition:all 0.2s;}
          #songs button:hover{background:rgba(255,255,255,0.22);color:#fff;}
          #songs button.active{background:rgba(255,255,255,0.92);color:#000;}
          #hud{position:fixed;left:16px;bottom:14px;color:rgba(255,255,255,0.6);
            font:12px/1.6 ui-monospace,monospace;text-shadow:0 1px 4px #000;
            pointer-events:none;z-index:10;}
          #hint{position:fixed;left:0;right:0;bottom:46px;text-align:center;
            color:rgba(255,255,255,0.8);font-size:15px;pointer-events:none;
            text-shadow:0 1px 6px #000;transition:opacity 0.5s;z-index:10;}
          #modebtn{position:fixed;top:10px;left:12px;z-index:11;
            background:rgba(255,255,255,0.1);color:rgba(255,255,255,0.72);
            border:1px solid rgba(255,255,255,0.18);border-radius:14px;padding:6px 14px;
            font:12px/1 -apple-system,system-ui,sans-serif;cursor:pointer;}
          #modebtn:hover{background:rgba(255,255,255,0.22);color:#fff;}
        </style>
        <script type="importmap">
        {
          "imports": {
            "three": "https://unpkg.com/three@0.160.0/build/three.module.js",
            "three/addons/": "https://unpkg.com/three@0.160.0/examples/jsm/"
          }
        }
        </script>
        </head>
        <body>
        <canvas id="grain"></canvas>
        <div id="songs"></div>
        <button id="modebtn">☁ Clouds</button>
        <div id="hint">click a song to play — drag to look around, scroll to zoom</div>
        <div id="hud"></div>
        <audio id="a"></audio>
        <script type="module">
        import * as THREE from 'three';
        import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

        const SONGS = \(songsJSON);
        const FPS = 30;

        // Temporal smoothing of the brightness/saturation channels (removes
        // strobing). Hue and onsets are left untouched.
        (function(){
          const radius = {s:7, b:7, tb:5, l:2, hc:6};
          for(const song of SONGS){
            const fr = song.frames;
            for(const key in radius){
              const R = radius[key];
              const orig = fr.map(f => f[key]);
              for(let i=0;i<fr.length;i++){
                let sum=0, n=0;
                const lo=Math.max(0,i-R), hi=Math.min(fr.length-1,i+R);
                for(let j=lo;j<=hi;j++){ sum+=orig[j]; n++; }
                fr[i][key] = sum/n;
              }
            }
          }
        })();

        let FRAMES = SONGS[0].frames;
        let DURATION = FRAMES.length / FPS;
        let songIndex = 0;

        const audio = document.getElementById('a');
        const hud = document.getElementById('hud');
        const bar = document.getElementById('songs');

        // --- Three.js scene -------------------------------------------------
        const scene = new THREE.Scene();
        // Linear fog: clear up close, dissolving into white mist with distance.
        scene.fog = new THREE.Fog(0xd4d8de, 11, 44);

        const camera = new THREE.PerspectiveCamera(62, innerWidth/innerHeight, 0.1, 200);
        camera.position.set(0, 1.5, 18);

        const renderer = new THREE.WebGLRenderer({ antialias: true });
        renderer.setPixelRatio(Math.min(2, devicePixelRatio));
        renderer.domElement.id = 'webgl';
        renderer.setClearColor(0x070709);
        document.body.appendChild(renderer.domElement);

        const controls = new OrbitControls(camera, renderer.domElement);
        controls.enableDamping = true;
        controls.dampingFactor = 0.08;
        controls.autoRotate = true;
        controls.autoRotateSpeed = 0.35;
        controls.minDistance = 2;
        controls.maxDistance = 44;

        // A soft radial-glow texture, tinted per sprite.
        const glowTex = (function(){
          const c = document.createElement('canvas');
          c.width = c.height = 128;
          const g = c.getContext('2d');
          const grad = g.createRadialGradient(64,64,0,64,64,64);
          grad.addColorStop(0,    'rgba(255,255,255,1)');
          grad.addColorStop(0.35, 'rgba(255,255,255,0.5)');
          grad.addColorStop(1,    'rgba(255,255,255,0)');
          g.fillStyle = grad;
          g.fillRect(0,0,128,128);
          return new THREE.CanvasTexture(c);
        })();

        function makeSprite(){
          const mat = new THREE.SpriteMaterial({
            map: glowTex, blending: THREE.NormalBlending,
            transparent: true, depthWrite: false, opacity: 0.7
          });
          const sprite = new THREE.Sprite(mat);
          scene.add(sprite);
          return sprite;
        }

        const mainClouds = [];
        for(let i=0;i<5;i++){
          mainClouds.push({ sprite: makeSprite(), px:0,py:0,pz:0, pvx:0,pvy:0,pvz:0 });
        }
        const detailClouds = [];
        for(let i=0;i<8;i++) detailClouds.push(makeSprite());
        const core = makeSprite();

        // --- ring particle system (mode 2) ----------------------------------
        const RING_COUNT = 16;
        const PER_RING = 200;
        const ringTotal = RING_COUNT * PER_RING;
        const ringPositions = new Float32Array(ringTotal*3);
        const ringColors = new Float32Array(ringTotal*3);
        const ringGeo = new THREE.BufferGeometry();
        ringGeo.setAttribute('position', new THREE.BufferAttribute(ringPositions,3));
        ringGeo.setAttribute('color', new THREE.BufferAttribute(ringColors,3));
        const ringSystem = new THREE.Points(ringGeo, new THREE.PointsMaterial({
          map: glowTex, size: 0.42, vertexColors: true,
          transparent: true, depthWrite: false,
          blending: THREE.NormalBlending, sizeAttenuation: true
        }));
        ringSystem.visible = false;
        scene.add(ringSystem);
        const ringRotation = new Float32Array(RING_COUNT);
        const ringIntensity = new Float32Array(RING_COUNT);
        let ringRipples = [];
        const tmpColor = new THREE.Color();

        // --- architecture (mode 3) ------------------------------------------
        const architectureGroup = new THREE.Group();
        architectureGroup.visible = false;
        scene.add(architectureGroup);
        let archRings = [];

        // --- grain overlay --------------------------------------------------
        const grainCanvas = document.getElementById('grain');
        const gctx = grainCanvas.getContext('2d');
        const noiseCanvas = document.createElement('canvas');
        noiseCanvas.width = noiseCanvas.height = 256;
        (function(){
          const nctx = noiseCanvas.getContext('2d');
          const img = nctx.createImageData(256,256);
          for(let i=0;i<img.data.length;i+=4){
            const v = Math.random()*255;
            img.data[i]=img.data[i+1]=img.data[i+2]=v;
            img.data[i+3]=255;
          }
          nctx.putImageData(img,0,0);
        })();
        const noisePattern = gctx.createPattern(noiseCanvas,'repeat');

        // --- state ----------------------------------------------------------
        let clock=0, driftPhase=0, lastNow=performance.now();
        let eLoud=0, eTimbre=0, eComplex=0, onsetKick=0;
        let grainX=0, grainY=0, lastIndex=-1;
        let mode = 0;   // 0 = clouds, 1 = rings

        function frameAt(time){
          let i = Math.round(time*FPS);
          if(i<0) i=0;
          if(i>=FRAMES.length) i=FRAMES.length-1;
          return FRAMES[i];
        }
        function crispness(tb){ return Math.max(0, Math.min(1, (tb-0.4)/0.5)); }
        function clamp01(x){ return Math.max(0, Math.min(1, x)); }

        // HSB to an existing THREE.Color.
        function setHSB(color,h,s,v){
          let i=Math.floor(h*6), f=h*6-i;
          let p=v*(1-s), q=v*(1-f*s), t=v*(1-(1-f)*s), r,g,b;
          switch(((i%6)+6)%6){
            case 0:r=v;g=t;b=p;break; case 1:r=q;g=v;b=p;break;
            case 2:r=p;g=v;b=t;break; case 3:r=p;g=q;b=v;break;
            case 4:r=t;g=p;b=v;break; default:r=v;g=p;b=q;
          }
          color.setRGB(r,g,b);
        }

        function resize(){
          camera.aspect = innerWidth/innerHeight;
          camera.updateProjectionMatrix();
          renderer.setSize(innerWidth,innerHeight);
          grainCanvas.width = innerWidth;
          grainCanvas.height = innerHeight;
        }
        addEventListener('resize', resize);
        resize();

        function loadSong(idx){
          songIndex = idx;
          FRAMES = SONGS[idx].frames;
          DURATION = FRAMES.length / FPS;
          buildArchitecture();
          clock=0; lastIndex=-1; eLoud=0; eTimbre=0; eComplex=0;
          onsetKick=0; driftPhase=0;
          for(const c of mainClouds){ c.px=c.py=c.pz=c.pvx=c.pvy=c.pvz=0; }
          audio.src = SONGS[idx].audio;
          audio.currentTime = 0;
          audio.play();
          document.getElementById('hint').style.opacity = 0;
          [...bar.children].forEach((b,i)=> b.classList.toggle('active', i===idx));
        }
        SONGS.forEach((s,idx)=>{
          const btn = document.createElement('button');
          btn.textContent = s.title;
          btn.onclick = ()=>loadSong(idx);
          bar.appendChild(btn);
        });

        // Rings mode — concentric rings of particles; onsets send ripples
        // traveling outward through them.
        function updateRings(clock, dt, f, breath){
          const sat = Math.min(1, 0.32 + eLoud*2.2);
          const baseV = Math.min(1, 0.45 + f.s*1.4);
          const activeRings = 4 + Math.round(eComplex * (RING_COUNT-4));
          ringRipples = ringRipples.filter(born => clock-born >= 0 && clock-born < 1.6);

          let idx = 0;
          for(let k=0;k<RING_COUNT;k++){
            const target = (k < activeRings) ? 1 : 0;
            ringIntensity[k] += (target - ringIntensity[k]) * Math.min(1, dt*3);
            const dir = (k % 2 === 0) ? 1 : -1;
            ringRotation[k] += dt * dir * (0.15 + eLoud*1.4) * (0.5 + k*0.05);

            const baseR = 1.8 + k*0.95;
            let ripple = 0;
            for(const born of ringRipples){
              const age = clock - born;
              const d = (baseR - age*12) / 2.2;          // gaussian at the wavefront
              ripple += 1.1 * Math.exp(-d*d) * (1 - age/1.6);
            }
            const r = (baseR + ripple) * (1 + breath*0.04);

            setHSB(tmpColor, f.h, sat, baseV * ringIntensity[k]);
            for(let p=0;p<PER_RING;p++){
              const a = (p/PER_RING)*6.2832 + ringRotation[k];
              ringPositions[idx*3]   = Math.cos(a)*r;
              ringPositions[idx*3+1] = Math.sin(a)*r;
              ringPositions[idx*3+2] = Math.sin(a*2 + ringRotation[k])*0.7;
              ringColors[idx*3]   = tmpColor.r;
              ringColors[idx*3+1] = tmpColor.g;
              ringColors[idx*3+2] = tmpColor.b;
              idx++;
            }
          }
          ringGeo.attributes.position.needsUpdate = true;
          ringGeo.attributes.color.needsUpdate = true;
        }

        // Architecture mode — the song stacks a spire of rings, one per onset.
        // Each ring is a permanent record: its color, width and detail are
        // fixed at the moment its onset occurred.
        function buildArchitecture(){
          for(const r of archRings){
            architectureGroup.remove(r.mesh);
            r.mesh.geometry.dispose();
            r.mesh.material.dispose();
          }
          archRings = [];
          const onsets = FRAMES.filter(fr => fr.o);
          if(onsets.length === 0) return;
          const spacing = 17 / onsets.length;
          for(let i=0;i<onsets.length;i++){
            const fr = onsets[i];
            const radius = 1.2 + fr.l*5;                 // loudness -> width
            const tube = 0.10 + fr.l*0.18;
            const detail = 10 + Math.round(fr.hc*38);    // complexity -> smoothness
            const col = new THREE.Color();
            setHSB(col, fr.h, Math.min(1,0.4+fr.l*1.8), Math.min(1,0.55+fr.s*1.4));
            const mesh = new THREE.Mesh(
              new THREE.TorusGeometry(radius, tube, 7, detail),
              new THREE.MeshBasicMaterial({ color: col })
            );
            mesh.rotation.x = Math.PI/2;                 // lay the ring flat
            mesh.position.y = -8.5 + i*spacing;
            mesh.visible = false;
            architectureGroup.add(mesh);
            archRings.push({ mesh: mesh, onsetTime: fr.t });
          }
        }
        function updateArchitecture(clock, dt){
          architectureGroup.rotation.y += dt*0.15;
          for(const r of archRings){
            const age = clock - r.onsetTime;
            if(age < 0){
              r.mesh.visible = false;
            } else {
              r.mesh.visible = true;
              const s = Math.min(1, age/0.3);            // pop-in growth
              r.mesh.scale.set(s,s,s);
            }
          }
        }

        function setMode(m){
          mode = m;
          for(const c of mainClouds) c.sprite.visible = (m===0);
          for(const d of detailClouds) d.visible = (m===0);
          core.visible = (m===0);
          ringSystem.visible = (m===1);
          architectureGroup.visible = (m===2);
          document.getElementById('modebtn').textContent =
            ['☁ Clouds','✦ Rings','⛰ Architecture'][m];
        }
        document.getElementById('modebtn').onclick = ()=> setMode((mode+1)%3);
        buildArchitecture();

        function animate(now){
          const dt = Math.min(0.1,(now-lastNow)/1000);
          lastNow = now;

          if(!audio.paused && audio.currentTime>0){ clock = audio.currentTime; }
          else { clock += dt; if(clock>DURATION) clock = 0; }

          const i = Math.max(0,Math.min(FRAMES.length-1,Math.round(clock*FPS)));
          const f = FRAMES[i];

          eLoud    += (f.l  - eLoud)    * Math.min(1,dt*5);
          eTimbre  += (f.tb - eTimbre)  * Math.min(1,dt*4);
          eComplex += (f.hc - eComplex) * Math.min(1,dt*3);

          const energy = 0.25 + Math.min(1, eLoud*2.6);
          driftPhase += dt * (0.35 + eLoud*2.0);
          const colorSpread = 0.15 + energy*0.5;
          grainX += dt*(8 + eLoud*380);
          grainY += dt*(6 + eLoud*300);

          const song = SONGS[songIndex];
          const beatPeriod = song.bpm>0 ? 60/song.bpm : 0.5;
          const breathAmt = clamp01((song.tempoConfidence-0.42)/0.18);
          const breath = Math.sin(clock/beatPeriod * 6.2832) * breathAmt;

          // Onsets kick every cloud in a random 3D direction.
          for(let k=lastIndex+1;k<=i;k++){
            if(FRAMES[k] && FRAMES[k].o){
              onsetKick = Math.min(1.6, onsetKick + 0.8*energy);
              ringRipples.push(clock);
              for(const c of mainClouds){
                const th=Math.random()*6.2832, ph=Math.acos(2*Math.random()-1);
                const mag=(3 + Math.random()*5)*energy;
                c.pvx += Math.sin(ph)*Math.cos(th)*mag;
                c.pvy += Math.sin(ph)*Math.sin(th)*mag;
                c.pvz += Math.cos(ph)*mag;
              }
            }
          }
          lastIndex = i;

          // Spring perturbations back toward rest — a damped 3D wobble.
          for(const c of mainClouds){
            c.pvx += (-22*c.px - 5.5*c.pvx)*dt;
            c.pvy += (-22*c.py - 5.5*c.pvy)*dt;
            c.pvz += (-22*c.pz - 5.5*c.pvz)*dt;
            c.px += c.pvx*dt; c.py += c.pvy*dt; c.pz += c.pvz*dt;
          }
          onsetKick += -onsetKick * Math.min(1, dt*4.5);

          // --- render the active mode ---
          if(mode === 0){
          // Main clouds.
          for(let m=0;m<5;m++){
            const c = mainClouds[m];
            const cf = frameAt(clock - m*colorSpread);
            const sat = Math.min(1, 0.30 + cf.l*2.2);
            const v = Math.min(0.96, 0.34 + cf.s*1.7 + cf.b*0.18 + eTimbre*0.12 + onsetKick*0.05);
            setHSB(c.sprite.material.color, cf.h, sat, v);
            const R = 7.5;
            c.sprite.position.set(
              R*Math.sin(driftPhase*(0.12+0.03*m) + m*1.7) + c.px,
              R*0.7*Math.sin(driftPhase*(0.10+0.035*m) + m*2.3) + c.py,
              R*Math.sin(driftPhase*(0.09+0.025*m) + m*0.9) + c.pz
            );
            const size = (9 + Math.min(1,eLoud*3.5)*5) * (1+onsetKick*0.12) * (1+breath*0.06);
            c.sprite.scale.set(size,size,1);
            c.sprite.material.opacity = 0.72;
          }

          // Detail clouds — visibility scales with harmonic complexity.
          for(let d=0;d<8;d++){
            const spr = detailClouds[d];
            if(eComplex > 0.04){
              spr.visible = true;
              const cf = frameAt(clock - d*0.22);
              const sat = Math.min(1, 0.30 + cf.l*2.2);
              const v = Math.min(0.96, 0.45 + cf.s*1.6);
              setHSB(spr.material.color, cf.h, sat, v);
              const R = 9.5;
              spr.position.set(
                R*Math.sin(driftPhase*(0.30+0.07*d) + d*2.1),
                R*0.8*Math.sin(driftPhase*(0.26+0.06*d) + d*1.3),
                R*Math.cos(driftPhase*(0.28+0.05*d) + d*0.7)
              );
              const size = 3 + Math.min(1,eLoud*3)*1.6;
              spr.scale.set(size,size,1);
              spr.material.opacity = 0.62 * eComplex;
            } else {
              spr.visible = false;
            }
          }

          // Central core.
          setHSB(core.material.color, f.h,
                 Math.min(1, 0.30 + eLoud*2.2),
                 Math.min(0.98, 0.6 + eTimbre*0.38));
          const coreSize = (2 + Math.min(1,eLoud*3.5)*3) * (1+onsetKick*0.10) * (1+breath*0.09);
          core.scale.set(coreSize,coreSize,1);
          core.material.opacity = 0.9;
          } else if(mode === 1){
            updateRings(clock, dt, f, breath);
          } else {
            updateArchitecture(clock, dt);
          }

          controls.update();
          renderer.render(scene, camera);

          // Grain overlay — drifts smoothly, intensity from timbre.
          gctx.clearRect(0,0,grainCanvas.width,grainCanvas.height);
          const grain = crispness(eTimbre);
          if(grain > 0.04){
            gctx.save();
            gctx.globalAlpha = grain * 0.13;
            gctx.translate(-(grainX%256), -(grainY%256));
            gctx.fillStyle = noisePattern;
            gctx.fillRect(0,0,grainCanvas.width+256,grainCanvas.height+256);
            gctx.restore();
          }

          hud.textContent =
            song.title + '   ·   t '+clock.toFixed(1)+'s   hue '+f.h.toFixed(2)+
            '   loud '+f.l.toFixed(2)+'   complexity '+f.hc.toFixed(2);

          requestAnimationFrame(animate);
        }
        requestAnimationFrame(animate);
        </script>
        </body>
        </html>
        """
    }
}
