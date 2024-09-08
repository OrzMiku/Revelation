/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

	Pass: Compute low-res clouds

--------------------------------------------------------------------------------
*/

#define CLOUD_LIGHTING

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 13 */
out vec4 cloudOut;

//======// Input //===============================================================================//

flat in vec3 directIlluminance;
flat in vec3 skyIlluminance;

//======// Uniform //=============================================================================//

uniform sampler2D noisetex;

uniform sampler3D COMBINED_TEXTURE_SAMPLER; // Combined atmospheric LUT

uniform sampler2D depthtex0;

uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;

uniform float nightVision;
uniform float wetness;
uniform float eyeAltitude;

uniform int moonPhase;
uniform int frameCounter;

uniform vec2 viewPixelSize;

uniform vec3 worldSunVector;
uniform vec3 worldLightVector;
uniform vec3 cameraPosition;
uniform vec3 lightningShading;

//======// Function //============================================================================//

#include "/lib/universal/Noise.glsl"
#include "/lib/universal/Offset.glsl"

#include "/lib/atmospherics/Global.glsl"
#include "/lib/atmospherics/PrecomputedAtmosphericScattering.glsl"

#include "/lib/atmospherics/clouds/CloudLayers.glsl"

vec3 ScreenToViewSpaceRaw(in vec3 screenPos) {	
	vec3 NDCPos = screenPos * 2.0 - 1.0;
	vec3 viewPos = projMAD(gbufferProjectionInverse, NDCPos);
	viewPos /= gbufferProjectionInverse[2].w * NDCPos.z + gbufferProjectionInverse[3].w;

	return viewPos;
}

float sampleDepthMax4x4(in vec2 coord) {
	// 4x4 pixel neighborhood using textureGather
	vec4 sampleDepth0 = textureGather(depthtex0, coord + vec2( 2.0,  2.0) * viewPixelSize);
	vec4 sampleDepth1 = textureGather(depthtex0, coord + vec2(-2.0,  2.0) * viewPixelSize);
	vec4 sampleDepth2 = textureGather(depthtex0, coord + vec2( 2.0, -2.0) * viewPixelSize);
	vec4 sampleDepth3 = textureGather(depthtex0, coord + vec2(-2.0, -2.0) * viewPixelSize);

	return max(max(maxOf(sampleDepth0), maxOf(sampleDepth1)), max(maxOf(sampleDepth2), maxOf(sampleDepth3)));
}

//======// Main //================================================================================//
void main() {
    ivec2 screenTexel = ivec2(gl_FragCoord.xy);

	ivec2 cloudTexel = screenTexel * CLOUD_TEMPORAL_UPSCALING + checkerboardOffset[frameCounter % cloudRenderArea];
	vec2 cloudUV = vec2(cloudTexel) * viewPixelSize;

	if (sampleDepthMax4x4(cloudUV) > 0.999999) {
		vec3 viewPos  = ScreenToViewSpaceRaw(vec3(cloudUV, 1.0));
		vec3 worldDir = mat3(gbufferModelViewInverse) * normalize(viewPos);

		float dither = R1(frameCounter / cloudRenderArea, texelFetch(noisetex, cloudTexel & 255, 0).a);

		cloudOut = RenderClouds(worldDir, dither);
	} else {
		cloudOut = vec4(0.0, 0.0, 0.0, 1.0);
	}
}