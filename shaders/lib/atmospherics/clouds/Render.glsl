/*
--------------------------------------------------------------------------------

	Referrence: 
		https://www.slideshare.net/guerrillagames/the-realtime-volumetric-cloudscapes-of-horizon-zero-dawn
		http://www.frostbite.com/2015/08/physically-based-unified-volumetric-rendering-in-frostbite/
		https://odr.chalmers.se/server/api/core/bitstreams/c8634b02-1b52-40c7-a75c-d8c7a9594c2c/content
		https://advances.realtimerendering.com/s2017/Nubis%20-%20Authoring%20Realtime%20Volumetric%20Cloudscapes%20with%20the%20Decima%20Engine%20-%20Final.pptx
		https://advances.realtimerendering.com/s2022/SIGGRAPH2022-Advances-NubisEvolved-NoVideos.pdf

--------------------------------------------------------------------------------
*/

#include "Layers.glsl"

//================================================================================================//

float CloudVolumeSunlightOD(in vec3 rayPos, in float lightNoise) {
    const float stepSize = CLOUD_CUMULUS_THICKNESS * (0.1 / float(CLOUD_CUMULUS_SUNLIGHT_SAMPLES));
	vec4 rayStep = vec4(cloudLightVector, 1.0) * stepSize;

    float opticalDepth = 0.0;

	for (uint i = 0u; i < CLOUD_CUMULUS_SUNLIGHT_SAMPLES; ++i, rayPos += rayStep.xyz) {
        rayStep *= 2.0;

		float density = CloudVolumeDensity(rayPos + rayStep.xyz * lightNoise, max(2u, 5u - i));
		if (density < 1e-5) continue;

        // opticalDepth += density * rayStep.w;
        opticalDepth += density;
    }

    return opticalDepth * 9.0;
}

float CloudVolumeSkylightOD(in vec3 rayPos, in float lightNoise) {
    const float stepSize = CLOUD_CUMULUS_THICKNESS * (0.1 / float(CLOUD_CUMULUS_SKYLIGHT_SAMPLES));
	vec4 rayStep = vec4(vec3(0.0, 1.0, 0.0), 1.0) * stepSize;

    float opticalDepth = 0.0;

	for (uint i = 0u; i < CLOUD_CUMULUS_SKYLIGHT_SAMPLES; ++i, rayPos += rayStep.xyz) {
        rayStep *= 2.0;

		float density = CloudVolumeDensity(rayPos + rayStep.xyz * lightNoise, max(2u, 4u - i));
		if (density < 1e-5) continue;

        // opticalDepth += density * rayStep.w;
        opticalDepth += density;
    }

    return opticalDepth * 3.0;
}

float CloudVolumeGroundLightOD(in vec3 rayPos) {
	// Estimate the light optical depth of the ground from the cloud volume
    return max0(rayPos.y - (CLOUD_CUMULUS_ALTITUDE + 40.0)) * 2.2e-2;
}

//================================================================================================//

vec4 RenderCloudPlane(in float stepT, in vec2 rayPos, in vec2 rayDir, in float LdotV, in float lightNoise, in vec4 phases) {
	float density = CloudPlaneDensity(rayPos);
	if (density > 1e-6) {
		// Siggraph 2017's new formula
		float opticalDepth = density * stepT;
		float absorption = oneMinus(max(fastExp(-opticalDepth), fastExp(-opticalDepth * 0.25) * 0.7));

		float stepSize = 32.0;
		vec2 rayPos = rayPos;
		vec3 rayStep = vec3(cloudLightVector.xz, 1.0) * stepSize;
		// float lightNoise = hash1(rayPos);

		opticalDepth = 0.0;
		// Compute the optical depth of sunlight through clouds
		for (uint i = 0u; i < 4u; ++i, rayPos += rayStep.xy) {
			float density = CloudPlaneDensity(rayPos + rayStep.xy * lightNoise);
			if (density < 1e-6) continue;

			rayStep *= 2.0;

			opticalDepth += density * rayStep.z;
		} opticalDepth = smin(opticalDepth, 56.0, 8.0);

		// Magic power function, looks not bad
		vec4 hitPhases = pow(phases, vec4(0.7 + 0.2 * saturate(opticalDepth)));

		// Compute sunlight multi-scattering
		float scatteringSun  = fastExp(-opticalDepth * 1.0)  * hitPhases.x;
			  scatteringSun += fastExp(-opticalDepth * 0.4)  * hitPhases.y;
			  scatteringSun += fastExp(-opticalDepth * 0.15) * hitPhases.z;
			  scatteringSun += fastExp(-opticalDepth * 0.05) * hitPhases.w;

		#if 0
			stepSize = 44.0;
			rayStep = vec3(rayDir, 1.0) * stepSize;

			opticalDepth = 0.0;
			// Compute the optical depth of skylight through clouds
			for (uint i = 0u; i < 2u; ++i, rayPos += rayStep.xy) {
				float density = CloudPlaneDensity(rayPos + rayStep.xy * lightNoise);
				if (density < 1e-6) continue;

				rayStep *= 2.0;

				opticalDepth += density * rayStep.z;
			}
		#else
			opticalDepth = density * 3e2;
		#endif

		// Compute skylight multi-scattering
		float scatteringSky = fastExp(-opticalDepth * 0.1);
		scatteringSky += 0.2 * fastExp(-opticalDepth * 0.02);

		// Compute powder effect
		// float powder = 2.0 * fastExp(-density * 36.0) * oneMinus(fastExp(-density * 72.0));
		float powder = rcp(fastExp(-density * (TAU / cirrusExtinction)) * 0.7 + 0.3) - 1.0;
		// powder = mix(powder, 0.3, 0.7 * pow1d5(maxEps(LdotV * 0.5 + 0.5)));

		#ifdef CLOUD_LOCAL_LIGHTING
			// Compute local lighting
			vec3 sunIlluminance, moonIlluminance;
			vec3 hitPos = vec3(rayPos.x, planetRadius + eyeAltitude + CLOUD_PLANE_ALTITUDE, rayPos.y);
			vec3 skyIlluminance = GetSunAndSkyIrradiance(hitPos, worldSunVector, sunIlluminance, moonIlluminance);
			vec3 directIlluminance = sunIlluminance + moonIlluminance;

			skyIlluminance += lightningShading * 4e-3;
			#ifdef AURORA
				skyIlluminance += auroraShading;
			#endif
		#endif

		vec3 scattering = scatteringSun * 40.0 * directIlluminance;
		scattering += scatteringSky * 0.2 * skyIlluminance;
		scattering *= oneMinus(0.6 * wetness) * powder * absorption * rcp(cirrusExtinction);

		return vec4(scattering, absorption);
	}
}

//================================================================================================//

vec4 RenderClouds(in vec3 rayDir/* , in vec3 skyRadiance */, in float dither) {
    vec4 cloudData = vec4(0.0, 0.0, 0.0, 1.0);
	float LdotV = dot(cloudLightVector, rayDir);

	// Compute phases for clouds' sunlight multi-scattering
	vec4 phases = vec4(
		MiePhaseClouds(LdotV, vec3(0.65, -0.4, 0.9), 	   vec3(0.65, 0.25, 0.1)),
		MiePhaseClouds(LdotV, vec3(0.65, -0.4, 0.9) * 0.7, vec3(0.65, 0.25, 0.1) * 0.55),
		MiePhaseClouds(LdotV, vec3(0.65, -0.4, 0.9) * 0.5, vec3(0.65, 0.25, 0.1) * 0.3),
		MiePhaseClouds(LdotV, vec3(0.65, -0.4, 0.9) * 0.3, vec3(0.65, 0.25, 0.1) * 0.17)
	);

	float r = viewerHeight; // length(camera)
	float mu = rayDir.y;	// dot(camera, rayDir) / r

	//================================================================================================//

	// Compute volumetric clouds
	#ifdef CLOUD_CUMULUS
		if ((rayDir.y > 0.0 && eyeAltitude < CLOUD_CUMULUS_ALTITUDE) // Below clouds
		 || (clamp(eyeAltitude, CLOUD_CUMULUS_ALTITUDE, cumulusMaxAltitude) == eyeAltitude) // In clouds
		 || (rayDir.y < 0.0 && eyeAltitude > cumulusMaxAltitude)) { // Above clouds

			// Compute cloud spherical shell intersection
			vec2 intersection = RaySphericalShellIntersection(r, mu, planetRadius + CLOUD_CUMULUS_ALTITUDE, planetRadius + cumulusMaxAltitude);

			if (intersection.y > 0.0) { // Intersect the volume

				// Special treatment for the eye inside the volume
				float isEyeInVolumeSmooth = oneMinus(saturate((eyeAltitude - cumulusMaxAltitude + 5e2) * 2e-3)) * oneMinus(saturate((CLOUD_CUMULUS_ALTITUDE - eyeAltitude + 50.0) * 3e-2));
				float stepLength = max0(mix(intersection.y, min(intersection.y, 2e4), isEyeInVolumeSmooth) - intersection.x);

				#if defined PROGRAM_PREPARE
					uint raySteps = uint(CLOUD_CUMULUS_SAMPLES * 0.6);
				#else
					uint raySteps = CLOUD_CUMULUS_SAMPLES;
					// raySteps = uint(raySteps * min1(0.5 + max0(stepLength - 1e2) * 5e-5)); // Reduce ray steps for vertical rays
					raySteps = uint(raySteps * (isEyeInVolumeSmooth + oneMinus(abs(rayDir) * 0.4))); // Reduce ray steps for vertical rays
				#endif

				// const float nearStepSize = 3.0;
				// const float farStepSizeOffset = 60.0;
				// const float stepAdjustmentDistance = 16384.0;

				// float stepSize = nearStepSize + (farStepSizeOffset / stepAdjustmentDistance) * max0(endLength - startLength);

				float stepSize = stepLength * rcp(float(raySteps));

				vec3 rayStep = stepSize * rayDir;
				ToPlanetCurvePos(rayStep);
				vec3 rayPos = (intersection.x + stepSize * dither) * rayDir + cameraPosition;
				ToPlanetCurvePos(rayPos);

				vec3 rayHitPos = vec3(0.0);
				float rayHitPosWeight = 0.0;

				vec2 stepScattering = vec2(0.0);
				float transmittance = 1.0;

				// float powderFactor = 0.75 * sqr(LdotV * 0.5 + 0.5);

				for (uint i = 0u; i < raySteps; ++i, rayPos += rayStep) {
					if (transmittance < minCloudTransmittance) break;
					if (rayPos.y < CLOUD_CUMULUS_ALTITUDE || rayPos.y > cumulusMaxAltitude) continue;

					float radius = distance(rayPos, cameraPosition);
					if (radius > planetRadius + cumulusMaxAltitude) continue;

					// Compute sample cloud density
					#if defined PROGRAM_PREPARE
						float density = CloudVolumeDensity(rayPos, 3u);
					#else
						float density = CloudVolumeDensity(rayPos, 5u);
					#endif

					if (density < 1e-5) continue;

					rayHitPos += rayPos * transmittance;
					rayHitPosWeight += transmittance;

					#if defined PROGRAM_PREPARE
						vec2 lightNoise = vec2(0.5);
					#else
						// Compute light noise
						vec2 lightNoise = hash2(fract(rayPos));
					#endif

					// Compute the optical depth of sunlight through clouds
					float opticalDepthSun = CloudVolumeSunlightOD(rayPos, lightNoise.x);

					// Magic power function, looks not bad
					vec4 hitPhases = pow(phases, vec4(0.8 + 0.2 * saturate(opticalDepthSun)));

					// Compute sunlight multi-scattering
					float scatteringSun  = fastExp(-opticalDepthSun * 2.0) * hitPhases.x;
						  scatteringSun += fastExp(-opticalDepthSun * 0.8) * hitPhases.y;
						  scatteringSun += fastExp(-opticalDepthSun * 0.3) * hitPhases.z;
						  scatteringSun += fastExp(-opticalDepthSun * 0.1) * hitPhases.w;

					// Compute the optical depth of skylight through clouds
					float opticalDepthSky = CloudVolumeSkylightOD(rayPos, lightNoise.y);
					float scatteringSky = fastExp(-opticalDepthSky) + fastExp(-opticalDepthSky * 0.2) * 0.2;

					// Compute the optical depth of ground light through clouds
					float opticalDepthGround = CloudVolumeGroundLightOD(rayPos);
					float scatteringGround = fastExp(-opticalDepthGround) * isotropicPhase;

					vec2 scattering = vec2(scatteringSun + scatteringGround * cloudLightVector.y, scatteringSky + scatteringGround * 0.5);

					// Siggraph 2017's new formula
					float stepOpticalDepth = density * cumulusExtinction * stepSize;
					float stepTransmittance = max(fastExp(-stepOpticalDepth), fastExp(-stepOpticalDepth * 0.25) * 0.7);

					// Compute powder effect
					float powder = rcp(fastExp(-density * (PI / cumulusExtinction)) * 0.85 + 0.15) - 1.0;
					// powder = mix(powder, 1.0, powderFactor);

					// Compute the integral of the scattering over the step
					float stepIntegral = transmittance * oneMinus(stepTransmittance);
					stepScattering += powder * scattering * stepIntegral;
					transmittance *= stepTransmittance;	
				}

				float absorption = 1.0 - transmittance;
				if (absorption > minCloudAbsorption) {
					stepScattering *= oneMinus(0.6 * wetness) * rcp(cumulusExtinction);
					rayHitPos /= rayHitPosWeight;
					FromPlanetCurvePos(rayHitPos);
					rayHitPos -= cameraPosition;

					#ifdef CLOUD_LOCAL_LIGHTING
						// Compute local lighting
						vec3 sunIlluminance, moonIlluminance;
						vec3 camera = vec3(0.0, planetRadius + eyeAltitude, 0.0);
						vec3 skyIlluminance = GetSunAndSkyIrradiance(camera + rayHitPos, worldSunVector, sunIlluminance, moonIlluminance);
						vec3 directIlluminance = sunIlluminance + moonIlluminance;
		
						skyIlluminance += lightningShading * 4e-3;
						#ifdef AURORA
							skyIlluminance += auroraShading;
						#endif
					#endif

					vec3 scattering = stepScattering.x * 2.4 * directIlluminance;
					scattering += stepScattering.y * 0.036 * skyIlluminance;

					// Compute aerial perspective
					#ifdef CLOUD_AERIAL_PERSPECTIVE
						vec3 airTransmittance;
						vec3 aerialPerspective = GetSkyRadianceToPoint(rayHitPos, worldSunVector, airTransmittance) * skyIntensity;

						scattering *= airTransmittance;
						scattering += aerialPerspective * absorption;
					#endif

					// Remap cloud transmittance
					transmittance = remap(minCloudTransmittance, 1.0, transmittance);

					cloudData = vec4(scattering, transmittance);
				}
			}
		}
	#endif

	//================================================================================================//

	// Compute planar clouds
	#if defined CLOUD_STRATOCUMULUS || defined CLOUD_CIRROCUMULUS || defined CLOUD_CIRRUS
		bool planetIntersection = RayIntersectsGround(r, mu);

		if ((rayDir.y > 0.0 && eyeAltitude < CLOUD_PLANE_ALTITUDE) // Below clouds
		 || (planetIntersection && eyeAltitude > CLOUD_PLANE_ALTITUDE)) { // Above clouds
			vec2 cloudIntersection = RaySphereIntersection(r, mu, planetRadius + CLOUD_PLANE_ALTITUDE);
			float cloudDistance = eyeAltitude > CLOUD_PLANE_ALTITUDE ? cloudIntersection.x : cloudIntersection.y;

			if (clamp(cloudDistance, 1e-6, planetRadius + CLOUD_PLANE_ALTITUDE) == cloudDistance) {
				vec3 cloudPos = rayDir * cloudDistance + cameraPosition;

				vec4 cloudTemp = vec4(0.0, 0.0, 0.0, 1.0);

				vec4 sampleTemp = RenderCloudPlane(cloudDistance * cirrusExtinction, cloudPos.xz, rayDir.xz, LdotV, dither, phases);

				// Compute aerial perspective
				#ifdef CLOUD_AERIAL_PERSPECTIVE
					if (sampleTemp.a > minCloudAbsorption) {
						vec3 airTransmittance;
						vec3 aerialPerspective = GetSkyRadianceToPoint(cloudPos - cameraPosition, worldSunVector, airTransmittance) * skyIntensity;
						sampleTemp.rgb *= airTransmittance;
						sampleTemp.rgb += aerialPerspective * sampleTemp.a;
					}
				#endif

				cloudTemp.rgb = sampleTemp.rgb;
				cloudTemp.a -= sampleTemp.a;
				if (eyeAltitude < CLOUD_PLANE_ALTITUDE) {
					// Below clouds
					cloudData.rgb += cloudTemp.rgb * cloudData.a;
				} else {
					// Above clouds
					cloudData.rgb = cloudData.rgb * cloudTemp.a + cloudTemp.rgb;
				}

				cloudData.a *= cloudTemp.a;
			}
		}
	#endif

	// Remap cloud transmittance
    cloudData.a = remap(minCloudTransmittance, 1.0, cloudData.a);

	#ifdef AURORA
		if (auroraAmount > 1e-2) cloudData.rgb += NightAurora(rayDir) * cloudData.a;
	#endif

    return cloudData;
}