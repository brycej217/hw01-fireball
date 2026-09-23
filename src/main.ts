import {vec3} from 'gl-matrix';
import Stats from 'stats-js';
import * as DAT from 'dat.gui';
// @ts-ignore: parse-hdr doesn't ship type definitions
import parseHdr from 'parse-hdr';
import Icosphere from './geometry/Icosphere';
import Square from './geometry/Square';
import OpenGLRenderer from './rendering/gl/OpenGLRenderer';
import Camera from './Camera';
import {setGL} from './globals';
import ShaderProgram, {Shader} from './rendering/gl/ShaderProgram';

import lambertVertSource from './shaders/lambert-vert.glsl?raw';
import lambertFragSource from './shaders/lambert-frag.glsl?raw';
import skyUrl from '../sky.hdr?url';

// default look of the cloud, restored by the 'Reset Cloud' button
const defaults = {
  tesselations: 6,
  puffiness: 1.0,
  puffScale: 1.0,
  octaves: 5,
};

// Define an object with application parameters and button callbacks
// This will be referred to by dat.GUI's functions that add GUI elements.
const controls = {
  tesselations: defaults.tesselations,
  puffiness: defaults.puffiness, // how far the puffs stick out
  puffScale: defaults.puffScale, // noise frequency, higher means more, smaller puffs
  octaves: defaults.octaves, // octaves of billowy detail
  'Load Scene': loadScene, // A function pointer, essentially
  'Reset Cloud': resetCloud,
};

let icosphere: Icosphere;
let square: Square;
let prevTesselations: number = defaults.tesselations;

function loadScene() {
  icosphere = new Icosphere(vec3.fromValues(0, 0, 0), 1, controls.tesselations);
  icosphere.create();
  square = new Square(vec3.fromValues(0, 0, 0));
  square.create();
}

// put every slider back to its default, tick() rebuilds the icosphere if tesselations changed
function resetCloud() {
  Object.assign(controls, defaults);
}

// downloads sky.hdr, parses it with parse-hdr, and uploads it into the sky texture
async function loadSky(gl: WebGL2RenderingContext, texture: WebGLTexture) {
  const response = await fetch(skyUrl);
  if (!response.ok) {
    throw new Error(`failed to load sky.hdr (${response.status})`);
  }

  // parse-hdr gives { shape: [width, height], data: rgba floats in linear light, top row first }
  const hdr = parseHdr(await response.arrayBuffer());
  const width: number = hdr.shape[0];
  const height: number = hdr.shape[1];
  const data: Float32Array = hdr.data;

  const maxSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  if (width > maxSize || height > maxSize) {
    throw new Error(`sky.hdr is ${width}x${height}, bigger than this gpu's max texture size (${maxSize})`);
  }

  // the texture stores half floats, anything above the half float max (e.g. the sun)
  // would turn into infinity and then NaN after tone mapping, so clamp it
  for (let i = 0; i < data.length; i++) {
    data[i] = Math.min(data[i], 65504);
  }

  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, width, height, 0, gl.RGBA, gl.FLOAT, data);
}

function main() {
  // Initial display for framerate
  const stats = Stats();
  stats.setMode(0);
  stats.domElement.style.position = 'absolute';
  stats.domElement.style.left = '0px';
  stats.domElement.style.top = '0px';
  document.body.appendChild(stats.domElement);

  // Add controls to the gui
  // .listen() makes a slider redraw when its value is changed from code, i.e. by the reset button
  const gui = new DAT.GUI();
  gui.add(controls, 'tesselations', 0, 8).step(1).listen();
  gui.add(controls, 'puffiness', 0, 2).step(0.05).listen();
  gui.add(controls, 'puffScale', 0.5, 3).step(0.05).listen();
  gui.add(controls, 'octaves', 1, 8).step(1).listen();
  gui.add(controls, 'Load Scene');
  gui.add(controls, 'Reset Cloud');

  // get canvas and webgl context
  const canvas = <HTMLCanvasElement> document.getElementById('canvas');
  const gl = <WebGL2RenderingContext> canvas.getContext('webgl2');
  if (!gl) {
    alert('WebGL 2 not supported!');
  }
  // `setGL` is a function imported above which sets the value of `gl` in the `globals.ts` module.
  // Later, we can import `gl` from `globals.ts` to access it
  setGL(gl);

  // Initial call to load scene
  loadScene();

  const camera = new Camera(vec3.fromValues(0, 0, 5), vec3.fromValues(0, 0, 0));

  const renderer = new OpenGLRenderer(canvas);
  renderer.setClearColor(0.2, 0.2, 0.2, 1);
  gl.enable(gl.DEPTH_TEST);

  const lambert = new ShaderProgram([
    new Shader(gl.VERTEX_SHADER, lambertVertSource),
    new Shader(gl.FRAGMENT_SHADER, lambertFragSource),
  ]);

  // sky texture, starts as a single dark pixel (about the old 0.2 gray after tone mapping)
  // so the shader always has a texture bound, then gets replaced once sky.hdr has downloaded
  const skyTexture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, skyTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, 1, 1, 0, gl.RGBA, gl.FLOAT, new Float32Array([0.03, 0.03, 0.03, 1.0]));

  // RGBA16F half floats keep the hdr range and can be linearly filtered in plain webgl2.
  // no mipmaps: webgl2 can't generate them for float textures without an extension,
  // and where u wraps from 1 back to 0 they would show up as a seam in the sky
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);        // longitude wraps around
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE); // latitude stops at the poles

  loadSky(gl, skyTexture).catch(err => console.error(err));

  // This function will be called every frame
  const startTime = performance.now();

  function tick() {
    camera.update();
    stats.begin();
    gl.viewport(0, 0, window.innerWidth, window.innerHeight);
    renderer.clear();

    // send the time and gui values to the shaders
    lambert.setTime((performance.now() - startTime) / 1000); // seconds since start time
    lambert.setPuffiness(controls.puffiness);
    lambert.setPuffScale(controls.puffScale);
    lambert.setOctaves(controls.octaves);
    lambert.setSkyTexture(skyTexture);

    if(controls.tesselations != prevTesselations)
    {
      prevTesselations = controls.tesselations;
      icosphere = new Icosphere(vec3.fromValues(0, 0, 0), 1, prevTesselations);
      icosphere.create();
    }

    // background: the square drawn as the sky, without writing depth so the cloud always draws in front
    lambert.setDrawSky(true);
    gl.depthMask(false);
    renderer.render(camera, lambert, [
      square,
    ]);
    gl.depthMask(true);

    // cloud
    lambert.setDrawSky(false);
    renderer.render(camera, lambert, [
      icosphere,
    ]);
    stats.end();

    // Tell the browser to call `tick` again whenever it renders a new frame
    requestAnimationFrame(tick);
  }

  window.addEventListener('resize', function() {
    renderer.setSize(window.innerWidth, window.innerHeight);
    camera.setAspectRatio(window.innerWidth / window.innerHeight);
    camera.updateProjectionMatrix();
  }, false);

  renderer.setSize(window.innerWidth, window.innerHeight);
  camera.setAspectRatio(window.innerWidth / window.innerHeight);
  camera.updateProjectionMatrix();

  // Start the render loop
  tick();
}

main();