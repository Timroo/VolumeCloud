// 体积云 光照Lit Loop优化 遮蔽剔除
Shader "VolumeCloud/7-CloudLitOccusion"
{
    Properties
    {
        [Header(Base)]
        [Space(10)]
        _Color("Color", Color) = (1, 1, 1, 1)
        _Absorption("Absorption", Range(0, 100)) = 50
        _Opacity("Opacity", Range(0, 100)) = 50
        [PowerSlider(10.0)] _Step("Step", Range(0.001, 0.1)) = 0.03

        [Header(Noise)]
        [Space(10)]
        _NoiseScale("NoiseScale", Range(0, 100)) = 5
        _Radius("Radius", Range(0, 2)) = 1.0

        [Header(Light)]
        [Space(10)]
        _AbsorptionLight("AbsorptionLight", Range(0, 100)) = 50
        _OpacityLight("OpacityLight", Range(0, 100)) = 50
        _LightStepScale("LightStepScale", Range(0, 1)) = 0.5
        [IntRange] _LoopLight("LoopLight", Range(0, 128)) = 6
    }

    CGINCLUDE
    #include "UnityCG.cginc"

    struct appdata
    {
        float4 vertex : POSITION;
    };

    struct v2f
    {
        float4 vertex : SV_POSITION;
        float3 worldPos : TEXCOORD0;
        float4 projPos : TEXCOORD1; // 当前片元的投影空间位置（用于深度采样）
    };

    float4 _Color;
    float _Absorption;
    float _Opacity;
    float _Step;

    float _NoiseScale;
    float _Radius;

    float _AbsorptionLight;
    float _OpacityLight;
    float _LightStepScale;
    int _LoopLight;

    float4 _LightColor0;

    // 用于遮蔽检测
    UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

    v2f vert(appdata v)
    {
        v2f o;
        o.vertex = UnityObjectToClipPos(v.vertex);
        o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
        o.projPos = ComputeScreenPos(o.vertex);
        COMPUTE_EYEDEPTH(o.projPos.z);
        return o;
    }

    // 伪随机数生成器
    inline float hash(float n){
        return frac(sin(n) * 43758.5453);
    }
    // 3D噪声
    inline float noise(float3 x){
        float3 p = floor(x);
        float3 f = frac(x);
        f = f * f * (3.0 - 2.0 * f);
        float n = p.x + p.y * 57.0 + 113.0 * p.z;
        float res =
        lerp(lerp(lerp(hash(n + 0.0), hash(n + 1.0), f.x),
        lerp(hash(n + 57.0), hash(n + 58.0), f.x), f.y),
        lerp(lerp(hash(n + 113.0), hash(n + 114.0), f.x),
        lerp(hash(n + 170.0), hash(n + 171.0), f.x), f.y),
        f.z);
        return res;
    }
    // 分形布朗运动（Fractal Brownian Motion）
    inline float fbm(float3 p){
        float3x3 m = float3x3(
        + 0.00, + 0.80, + 0.60,
        - 0.80, + 0.36, - 0.48,
        - 0.60, - 0.48, + 0.64);
        float f = 0.0;
        f += 0.5 * noise(p); p = mul(m, p) * 2.02;
        f += 0.3 * noise(p); p = mul(m, p) * 2.03;
        f += 0.2 * noise(p);
        return f;
    }

    inline float densityFunction(float3 p){
        return fbm(p * _NoiseScale) - length(p / _Radius);
    }

    // 最大穿透距离计算
    inline float AABBTraverseDist(float3 dir, float3 pos){
        float3 invLocalDir = 1.0 / dir;
        float3 t1 = (- 0.5 - pos) * invLocalDir;
        float3 t2 = (+ 0.5 - pos) * invLocalDir;
        float3 tmax3 = max(t1, t2); // 退出包围盒的点
        // 最大穿透距离：最远能走的距离，由最先离开某个轴控制
        float2 tmax2 = min(tmax3.xx, tmax3.yz);
        float traverseDist = min(tmax2.x, tmax2.y);
        return traverseDist;
    }

    // Raymarching体积采样器
    void Sample_Raymatching(float3 pos, float step, float lightStep, inout float4 color, inout float transmittance){
        float density = densityFunction(pos);
        if(density < 0.0) return;

        float d = density * step;
        transmittance *= 1.0 - d * _Absorption;
        if(transmittance < 0.01) return;

        float transmittanceLight = 1.0;
        float3 lightPos = pos;
        for(int j = 0; j < _LoopLight; ++ j){
            float densityLight = densityFunction(lightPos);
            if(densityLight > 0.0){
                float dl = densityLight * lightStep;
                transmittanceLight *= 1.0 - dl * _AbsorptionLight;
                if(transmittanceLight < 0.01)
                {
                    transmittanceLight = 0.0;
                    break;
                }
            }
            lightPos += lightStep;
        }

        color.a += _Color.a * (_Opacity * d * transmittance);
        color.rgb += _LightColor0 * (_OpacityLight * d * transmittance * transmittanceLight);
        color = clamp(color, 0.0, 1.0);
    }


    float MaxRaymarchDistance(
    float4 projPos, // 当前片元的投影空间位置（用于深度采样）
    float3 worldPos, // 当前片元的世界空间位置（Ray 起点）
    float3 worldDir) // 从摄像机到片元的射线方向
    {
        // 从摄像机深度图中采样真实视距
        float depth = LinearEyeDepth(SAMPLE_DEPTH_TEXTURE_PROJ(_CameraDepthTexture, UNITY_PROJ_COORD(projPos)));

        // 获取摄像机前方向（Z轴负方向）
        float3 cameraForward = - UNITY_MATRIX_V[2].xyz;

        // 将视线方向的深度转换为 worldDir 方向的距离
        float cameraToDepth = depth / dot(worldDir, cameraForward);

        // 摄像机到当前体积起始点的距离
        float cameraToStart = length(worldPos - _WorldSpaceCameraPos);

        // 得到可行最大距离（防止体积光穿透场景实体）
        return cameraToDepth - cameraToStart;
    }


    float4 frag(v2f i) : SV_Target
    {
        // 获取射线方向
        float3 worldPos = i.worldPos;
        float3 worldDir = normalize(worldPos - _WorldSpaceCameraPos);
        float3 camToWorldPos = worldPos - _WorldSpaceCameraPos;

        // 视角方向的Raymarch参数
        float3 localPos = mul(unity_WorldToObject, float4(worldPos, 1.0));
        float3 localDir = UnityWorldToObjectDir(worldDir);
        float3 localStep = localDir * _Step;

        // 起点对齐 & jitter抖动
        localPos += (_Step - fmod(length(UnityWorldToObjectDir(camToWorldPos)), _Step)) * localDir;
        float jitter = hash(localPos.x + localPos.y * 1000 + localPos.z * 10000 + _Time.x);
        localPos += localStep * jitter;

        // 穿透AABB的最大距离
        float traverseDist = AABBTraverseDist(localDir, localPos);
        int loop = floor(traverseDist / _Step);

        // 光照方向的Raymarch参数
        float lightStep = 1.0 / _LoopLight;
        float3 localLightDir = UnityWorldToObjectDir(_WorldSpaceLightPos0.xyz);
        float3 localLightStep = localLightDir * lightStep * _LightStepScale;

        // 【深度裁剪】
        float maxLen = MaxRaymarchDistance(i.projPos, worldPos, worldDir);
        float len = 0.f;

        // 初始化输出值
        float4 color = float4(_Color.rgb, 0.0);
        float transmittance = 1.0;

        // Raymarching
        for(int i = 0; i < loop; ++ i){
            Sample_Raymatching(localPos, _Step, lightStep, color, transmittance);
            len += _Step;
            if(len > maxLen) break;
            localPos += localStep;
        }

        // 尾部采样补偿
        if(len > maxLen){
            float step = maxLen - (len - _Step);
            localPos += step * localDir;
            Sample_Raymatching(localPos, step, lightStep, color, transmittance);
        }

        return color;
    }
    ENDCG

    SubShader
    {
        Tags { "Queue" = "Transparent" "RenderType" = "Transparent" }

        Pass
        {
            Cull Back
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha
            // Lighting Off //不参与光照

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma shader_feature _DEBUG_RENDER_LOOP_ON
            ENDCG
        }
    }
}
