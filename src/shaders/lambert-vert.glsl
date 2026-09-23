#version 300 es

uniform mat4 u_Model;       // The matrix that defines the transformation of the
                            // object we're rendering. In this assignment,
                            // this will be the result of traversing your scene graph.

uniform mat4 u_ModelInvTr;  // The inverse transpose of the model matrix.
                            // This allows us to transform the object's normals properly
                            // if the object has been non-uniformly scaled.

uniform mat4 u_ViewProj;    // The matrix that defines the camera's transformation.
                            // We've written a static matrix for you to use for HW2,
                            // but in HW3 you'll have to generate one yourself

uniform float u_Time; // time in seconds since start, used to animate the displacement
uniform float u_Puffiness; // gui: how far the puffs stick out, 1.0 is the default look
uniform float u_PuffScale; // gui: noise frequency multiplier, higher means more, smaller puffs
uniform int u_Octaves; // gui: number of fbm octaves in the billowy detail
uniform bool u_DrawSky; // true while drawing the background square, false while drawing the cloud

in vec4 vs_Pos;             // The array of vertex positions passed to the shader

in vec4 vs_Nor;             // The array of vertex normals passed to the shader

in vec4 vs_Col;             // The array of vertex colors passed to the shader.

out vec4 fs_Nor;            // The array of normals that has been transformed by u_ModelInvTr. This is implicitly passed to the fragment shader.
out vec4 fs_LightVec;       // The direction in which our virtual light lies, relative to each vertex. This is implicitly passed to the fragment shader.
out vec4 fs_Col;            // The color of each vertex. This is implicitly passed to the fragment shader.
out vec3 fs_Pos;
out float fs_Disp; // how far the vertex was pushed out, used to shade the cloud in the fragment shader
out vec3 fs_SkyDir; // world space view ray, only used while drawing the sky

const vec4 lightPos = vec4(5, 5, 3, 1); //The position of our virtual light, which is used to compute the shading of
                                        //the geometry in the fragment shader.

// returns random gradient vector
vec3 randomGradient3(vec3 p) 
{
    // hash p into pseudorandom angle
    p = p + 0.02;
    float x = dot(p, vec3(123.4, 234.5, 345.6));
    float y = dot(p, vec3(234.5, 345.6, 456.7));
    float z = dot(p, vec3(345.6, 456.7, 567.8));
    vec3 grad = vec3(x, y, z);
    grad = sin(grad) * 43758.5453;
    return normalize(sin(grad));
}


// easing function used by improved perlin noise
float ease(float t)
{
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// perlin noise function
float perlin(vec3 p)
{
    // 1. get local position in unit cube
    vec3 pi = floor(p); // get integer coords of bottom-left corner of unit cube
    vec3 pf = p - pi; // get fractional (position) within unit cell

    // 2. get corner positions using pi (bottom-left)
    vec3 c000 = pi + vec3(0.0, 0.0, 0.0);
    vec3 c100 = pi + vec3(1.0, 0.0, 0.0);
    vec3 c010 = pi + vec3(0.0, 1.0, 0.0);
    vec3 c110 = pi + vec3(1.0, 1.0, 0.0);
    vec3 c001 = pi + vec3(0.0, 0.0, 1.0);
    vec3 c101 = pi + vec3(1.0, 0.0, 1.0);
    vec3 c011 = pi + vec3(0.0, 1.0, 1.0);
    vec3 c111 = pi + vec3(1.0, 1.0, 1.0);

    // 3. calculate distance vectors + dot products against gradient vectors
    float d000 = dot(randomGradient3(c000), pf - vec3(0.0, 0.0, 0.0));
    float d100 = dot(randomGradient3(c100), pf - vec3(1.0, 0.0, 0.0));
    float d010 = dot(randomGradient3(c010), pf - vec3(0.0, 1.0, 0.0));
    float d110 = dot(randomGradient3(c110), pf - vec3(1.0, 1.0, 0.0));
    float d001 = dot(randomGradient3(c001), pf - vec3(0.0, 0.0, 1.0));
    float d101 = dot(randomGradient3(c101), pf - vec3(1.0, 0.0, 1.0));
    float d011 = dot(randomGradient3(c011), pf - vec3(0.0, 1.0, 1.0));
    float d111 = dot(randomGradient3(c111), pf - vec3(1.0, 1.0, 1.0));

    // 4. interpolate between values (trilinear)
    vec3 f = vec3(ease(pf.x), ease(pf.y), ease(pf.z));

    // mix between 4 edges
    float x00 = mix(d000, d100, f.x);
    float x10 = mix(d010, d110, f.x);
    float x01 = mix(d001, d101, f.x);
    float x11 = mix(d011, d111, f.x);

    // mix along 2 faces
    float y0 = mix(x00, x10, f.y);
    float y1 = mix(x01, x11, f.y);

    return mix(y0, y1, f.z);
}

// fractal brownian motion, sums octaves of perlin noise
// abs() folds each octave at zero, so it forms rounded billows with sharp creases
// between them, like the surface of a cumulus cloud
float fbm(vec3 p)
{
    float total = 0.0;
    float amplitude = 0.4;
    float frequency = 1.0;
    int octaves = u_Octaves; // from the gui

    for (int i = 0; i < octaves; i++)
    {
        total += abs(perlin(p * frequency)) * amplitude;
        frequency *= 2.0; // each octave is twice the frequency
        amplitude *= 0.4; // each octave is 0.4x the amplitude of the one before
    }

    return total;
}

// f(x, y, z) = h, how far to push a point out along its normal
float displacement(vec3 p)
{
    // 1. low frequency, high amplitude: slow combination of sin waves so the cloud gently swells
    float lowAmplitude = 0.2;
    float lowFreq = 1.5;
    float lowSpeed = 0.4;

    float wave = sin(lowFreq * p.x + u_Time * lowSpeed)
               + sin(lowFreq * 1.3 * p.y - u_Time * lowSpeed * 0.7)
               + sin(lowFreq * 0.8 * p.z + u_Time * lowSpeed * 1.4);
    wave = (wave / 3.0) * 0.5 + 0.5; // remap from [-3, 3] to [0, 1]

    // 2. high frequency, low amplitude: billowy fbm drifting sideways
    float highAmplitude = 0.25 * u_Puffiness;
    float highFreq = 3.0 * u_PuffScale;
    float highSpeed = 0.15;

    float detail = fbm(p * highFreq + vec3(u_Time * highSpeed, 0.0, 0.0));

    // 3. puff out the middle of the sphere so the cloud is wider than it is tall
    float puffHeight = 0.7 * u_Puffiness;
    float puffFreq = 2.0 * u_PuffScale;
    float puffSpeed = 0.1;

    float middle = 1.0 - smoothstep(0.0, 0.6, abs(normalize(p).y)); // 1 at the equator, 0 once |y| > 0.6
    float puff = perlin(p * puffFreq + vec3(u_Time * puffSpeed, 0.0, 0.0));
    puff = clamp(puff * 0.5 + 0.5, 0.0, 1.0); // remap to [0, 1]

    return lowAmplitude * wave + highAmplitude * detail + puffHeight * middle * puff;
}

void main()
{
    // background pass: the square's corners are already at the corners of the screen in [-1, 1],
    // so unproject each one onto the near and far planes, the view ray is the line between them
    if (u_DrawSky)
    {
        mat4 invViewProj = inverse(u_ViewProj);
        vec4 nearPoint = invViewProj * vec4(vs_Pos.xy, -1.0, 1.0);
        vec4 farPoint = invViewProj * vec4(vs_Pos.xy, 1.0, 1.0);
        fs_SkyDir = farPoint.xyz / farPoint.w - nearPoint.xyz / nearPoint.w;

        gl_Position = vec4(vs_Pos.xy, 0.0, 1.0); // straight onto the screen, no camera transform
        return;
    }

    fs_Col = vs_Col;

    mat3 invTranspose = mat3(u_ModelInvTr);
    fs_Nor = vec4(invTranspose * vec3(vs_Nor), 0); 

    // push each vertex out along its normal by f(x, y, z)
    float h = displacement(vs_Pos.xyz);
    vec4 pos = vec4(vs_Pos.xyz + normalize(vs_Nor.xyz) * h, 1.0);
    fs_Disp = h;

    // flatten the bottom like the base of a cumulus cloud
    float cloudBase = -0.6;
    pos.y = max(pos.y, cloudBase);

    vec4 modelposition = u_Model * pos;

    fs_LightVec = lightPos - modelposition; 

    fs_Pos = modelposition.xyz;

    gl_Position = u_ViewProj * modelposition;// gl_Position is a built-in variable of OpenGL which is
                                             // used to render the final positions of the geometry's vertices
}
