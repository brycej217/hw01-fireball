#version 300 es

precision highp float;

uniform float u_Time; // time in seconds since start, used to drift the wisps
uniform float u_Puffiness; // gui: how far the puffs stick out, shared with the vertex shader
uniform highp sampler2D u_Sky; // equirectangular hdr sky in linear light, highp so hdr values aren't clamped on mobile
uniform bool u_DrawSky; // true while drawing the background square, false while drawing the cloud

// These are the interpolated values out of the rasterizer, so you can't know
// their specific values without knowing the vertices that contributed to them
in vec4 fs_Nor;
in vec4 fs_LightVec;
in vec4 fs_Col;
in vec3 fs_Pos;
in float fs_Disp; // how far the vertex shader pushed this point out
in vec3 fs_SkyDir; // world space view ray, only used while drawing the sky

out vec4 out_Col; // This is the final output color that you will see on your
                  // screen for the pixel that is currently being processed.

const float PI = 3.14159265359;

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

// looks up the hdr sky in a world space direction and converts it to a displayable color
vec3 skyColor(vec3 dir)
{
    // 1. direction to equirectangular uv
    //    u is the angle around the y axis, v is the angle down from straight up
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
    vec3 hdr = texture(u_Sky, vec2(u, v)).rgb;

    // 2. tone map: hdr values go way past 1.0 (especially the sun), reinhard squeezes them into 0,1 
    float exposure = 1.0;
    vec3 color = hdr * exposure;
    color = color / (1.0 + color);

    // 3. gamma: the hdr file stores linear light, the screen expects gamma encoded values
    return pow(color, vec3(1.0 / 2.2));
}

void main()
{
    // background pass
    if (u_DrawSky)
    {
        out_Col = vec4(skyColor(normalize(fs_SkyDir)), 1.0);
        return;
    }

    // lambertian calculation, wrapped from [-1, 1] to [0, 1] so the dark side stays soft
    float diffuseTerm = dot(normalize(fs_Nor), normalize(fs_LightVec));
    diffuseTerm = diffuseTerm * 0.5 + 0.5;

    // displacement: puffs that stick out catch more light, the creases between them are shadowed
    float maxDisp = 0.2 + 0.5 * u_Puffiness; // roughly the largest displacement the vertex shader produces, 0.7 at the default puffiness
    float puffiness = smoothstep(0.0, maxDisp, fs_Disp);

    // height: the flat base of the cloud is darker than the top
    float height = smoothstep(-0.6, 1.0, fs_Pos.y);

    // perlin calculation, wisps drifting sideways in the same direction as the vertex shader
    float zoom = 4.0;
    float windSpeed = 0.3;
    float wisp = perlin(fs_Pos * zoom + vec3(u_Time * windSpeed, 0.0, 0.0));

    // combine everything into how lit this point is
    float lightIntensity = diffuseTerm * 0.4 + puffiness * 0.3 + height * 0.3 + wisp * 0.1;
    lightIntensity = clamp(lightIntensity, 0.0, 1.0);

    // blend colors
    vec3 shadowColor = vec3(0.55, 0.6, 0.72); // cool blue gray
    vec3 litColor = vec3(1.0, 1.0, 1.0);
    vec3 surface = mix(shadowColor, litColor, lightIntensity);
    out_Col = vec4(surface, 1.0);
}
