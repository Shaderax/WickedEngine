#define SURFACE_LOAD_QUAD_DERIVATIVES
#include "globals.hlsli"
#include "ShaderInterop_Renderer.h"
#include "brdf.hlsli"
#include "raytracingHF.hlsli"

PUSHCONSTANT(push, VisibilityResolvePushConstants);

#ifdef VISIBILITY_MSAA
Texture2DMS<uint> input_primitiveID : register(t0);
#else
Texture2D<uint> input_primitiveID : register(t0);
#endif // VISIBILITY_MSAA

RWTexture2D<float> output_depth_mip0 : register(u0);
RWTexture2D<float> output_depth_mip1 : register(u1);
RWTexture2D<float> output_depth_mip2 : register(u2);
RWTexture2D<float> output_depth_mip3 : register(u3);
RWTexture2D<float> output_depth_mip4 : register(u4);

RWTexture2D<float> output_lineardepth_mip0 : register(u5);
RWTexture2D<float> output_lineardepth_mip1 : register(u6);
RWTexture2D<float> output_lineardepth_mip2 : register(u7);
RWTexture2D<float> output_lineardepth_mip3 : register(u8);
RWTexture2D<float> output_lineardepth_mip4 : register(u9);

RWTexture2D<float2> output_velocity : register(u10);
RWTexture2D<float2> output_normal : register(u11);
RWTexture2D<unorm float> output_roughness : register(u12);
#ifdef VISIBILITY_MSAA
RWTexture2D<uint> output_primitiveID : register(u13);
#endif // VISIBILITY_MSAA

RWStructuredBuffer<ShaderTypeBin> output_bins : register(u14);

groupshared uint local_bin_counts[SHADERTYPE_BIN_COUNT + 1];

[numthreads(8, 8, 1)]
void main(uint groupIndex : SV_GroupIndex, uint3 Gid : SV_GroupID)
{
	if (groupIndex < SHADERTYPE_BIN_COUNT + 1)
	{
		local_bin_counts[groupIndex] = 0;
	}
	GroupMemoryBarrierWithGroupSync();

	// this is needed to have correct quad derivatives:
	uint2 GTid = remap_lane_8x8(groupIndex);
	uint2 pixel = Gid.xy * 8 + GTid;

	const float2 uv = ((float2)pixel + 0.5) * GetCamera().internal_resolution_rcp;
	const float2 clipspace = uv_to_clipspace(uv);
	RayDesc ray = CreateCameraRay(clipspace);

	float3 rayDirection_quad_x = QuadReadAcrossX(ray.Direction);
	float3 rayDirection_quad_y = QuadReadAcrossY(ray.Direction);

	uint primitiveID = input_primitiveID[pixel];

#ifdef VISIBILITY_MSAA
	[branch]
	if (push.options & VISIBILITY_RESOLVE_PRIMITIVEID)
	{
		output_primitiveID[pixel] = primitiveID;
	}
#endif // VISIBILITY_MSAA

	float3 pre;
	float depth;
	[branch]
	if (any(primitiveID))
	{
		PrimitiveID prim;
		prim.unpack(primitiveID);

		Surface surface;
		surface.init();

		[branch]
		if (surface.load(prim, ray.Origin, ray.Direction, rayDirection_quad_x, rayDirection_quad_y))
		{
			pre = surface.pre;
			float4 tmp = mul(GetCamera().view_projection, float4(surface.P, 1));
			tmp.xyz /= tmp.w;
			depth = tmp.z;

#ifndef VISIBILITY_FAST
			[branch]
			if (push.options & VISIBILITY_RESOLVE_NORMAL)
			{
				output_normal[pixel] = encode_oct(surface.N);
			}
			[branch]
			if (push.options & VISIBILITY_RESOLVE_ROUGHNESS)
			{
				output_roughness[pixel] = surface.roughness;
			}
#endif // VISIBILITY_FAST

			InterlockedAdd(local_bin_counts[surface.material.shaderType], 1);
		}
	}
	else
	{
		pre = ray.Origin + ray.Direction * GetCamera().z_far;
		depth = 0;
		InterlockedAdd(local_bin_counts[SHADERTYPE_BIN_COUNT], 1);
	}

#ifndef VISIBILITY_FAST
	[branch]
	if (push.options & VISIBILITY_RESOLVE_VELOCITY)
	{
		float2 pos2D = clipspace;
		float4 pos2DPrev = mul(GetCamera().previous_view_projection, float4(pre, 1));
		pos2DPrev.xy /= pos2DPrev.w;
		float2 velocity = ((pos2DPrev.xy - GetCamera().temporalaa_jitter_prev) - (pos2D.xy - GetCamera().temporalaa_jitter)) * float2(0.5, -0.5);
		output_velocity[pixel] = velocity;
	}
#endif // VISIBILITY_FAST

	GroupMemoryBarrierWithGroupSync();
	if (groupIndex < SHADERTYPE_BIN_COUNT + 1)
	{
		InterlockedAdd(output_bins[groupIndex].count, local_bin_counts[groupIndex]);
	}

	// Downsample depths:
	[branch]
	if (push.options & VISIBILITY_RESOLVE_DEPTH)
	{
		output_depth_mip0[pixel] = depth;

		if (GTid.x % 2 == 0 && GTid.y % 2 == 0)
		{
			output_depth_mip1[pixel / 2] = depth;
		}

		if (GTid.x % 4 == 0 && GTid.y % 4 == 0)
		{
			output_depth_mip2[pixel / 4] = depth;
		}

		if (GTid.x % 8 == 0 && GTid.y % 8 == 0)
		{
			output_depth_mip3[pixel / 8] = depth;
		}

		if (GTid.x % 16 == 0 && GTid.y % 16 == 0)
		{
			output_depth_mip4[pixel / 16] = depth;
		}
	}
	[branch]
	if (push.options & VISIBILITY_RESOLVE_LINEARDEPTH)
	{
		float lineardepth = compute_lineardepth(depth) * GetCamera().z_far_rcp;
		output_lineardepth_mip0[pixel] = lineardepth;

		if (GTid.x % 2 == 0 && GTid.y % 2 == 0)
		{
			output_lineardepth_mip1[pixel / 2] = lineardepth;
		}

		if (GTid.x % 4 == 0 && GTid.y % 4 == 0)
		{
			output_lineardepth_mip2[pixel / 4] = lineardepth;
		}

		if (GTid.x % 8 == 0 && GTid.y % 8 == 0)
		{
			output_lineardepth_mip3[pixel / 8] = lineardepth;
		}

		if (GTid.x % 16 == 0 && GTid.y % 16 == 0)
		{
			output_lineardepth_mip4[pixel / 16] = lineardepth;
		}
	}

}
