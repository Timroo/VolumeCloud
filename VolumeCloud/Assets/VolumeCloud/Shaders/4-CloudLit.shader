// 体积云 光照Lit
Shader "VolumeCloud/4-CloudLit"
{
    Properties
    {
        [Header(Base)]
        [Space(10)]
        _Color("Color", Color) = (1, 1, 1, 1)
        _Absorption("Absorption", Range(0, 100)) = 50
        _Opacity("Opacity", Range(0, 100)) = 50
        [IntRange] _Loop("Loop", Range(0, 128)) = 32

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
    };

    float4 _Color;
    float _Absorption;
    float _Opacity;
    int _Loop;

    float _NoiseScale;
    float _Radius;
    
    float _AbsorptionLight;
    float _OpacityLight;
    float _LightStepScale;
    int _LoopLight;
    
    float4 _LightColor0;

    // ref. https://www.shadertoy.com/view/lss3zr
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
            lerp(lerp(lerp(hash(n +   0.0), hash(n +   1.0), f.x),
                      lerp(hash(n +  57.0), hash(n +  58.0), f.x),f.y),
                 lerp(lerp(hash(n + 113.0), hash(n + 114.0), f.x),
                      lerp(hash(n + 170.0), hash(n + 171.0), f.x),f.y),
                 f.z);
        return res; 
    }
    // 分形布朗运动（Fractal Brownian Motion）
    // - 自然，层次丰富的噪声，用于云、火焰、水面模拟
    inline float fbm(float3 p){
        float3x3 m = float3x3(
            +0.00, +0.80, +0.60,
            -0.80, +0.36, -0.48,
            -0.60, -0.48, +0.64);
        float f = 0.0;
        // 第一层噪声（最大强度）
        f += 0.5 * noise(p); p = mul(m, p) * 2.02;
        // 第二层噪声（中等强度）
        f += 0.3 * noise(p); p = mul(m, p) * 2.03;
        // 第三层噪声（最弱）
        f += 0.2 * noise(p);
        return f;
    }

    inline float densityFunction(float3 p){
        // fbm - 控制噪声的结构复杂度
        // length - p远离模型中心的距离
        return fbm(p * _NoiseScale) - length(p / _Radius);
    }

    v2f vert(appdata v)
    {
        v2f o;
        o.vertex = UnityObjectToClipPos(v.vertex);
        o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
        return o;
    }

    float4 frag(v2f i) : SV_Target
    {
        float step = 1.0 / _Loop;
        float3 worldPos = i.worldPos;
        float3 worldDir = normalize(worldPos - _WorldSpaceCameraPos);

        // 模型空间:视角方向rayMarch
        float3 localPos = mul(unity_WorldToObject, float4(worldPos, 1.0));
        float3 localDir = UnityWorldToObjectDir(worldDir);
        float3 localStep = localDir * step; // 单位向量 * 1/Loop
        // 为每条射线加入一个“起始偏移”，避免 banding 条纹伪影
        float jitter = hash(localPos.x + localPos.y * 10 + localPos.z * 100 + _Time.x);
        localPos += localStep * jitter;

        // 光照方向 rayMarch
        float lightStep = 1.0 / _LoopLight;
        float3 localLightDir = UnityWorldToObjectDir(_WorldSpaceLightPos0.xyz);
        float3 localLightStep = localLightDir * lightStep * _LightStepScale;

        // 初始化输出值
        float4 color = float4(_Color.rgb, 0.0);
        float transmittance = 1.0;

        // Raymarching
        for(int i = 0; i < _Loop ; ++i){
            float density = densityFunction(localPos);
            
            if(density > 0.0){
                // 【视线方向体积衰减】
                float d = density * step;
                // 通过率会被层层递减，如果遮挡过多就被完全挡住，跳出循环
                transmittance *= 1.0 - d * _Absorption;
                if(transmittance < 0.01) break;

                // 【光照方向的体积穿透（次级RayMarching）,制造内部阴影】
                float transmittanceLight = 1.0;
                float3 lightPos = localPos;

                for(int j = 0; j < _LoopLight; ++j){
                    float densityLight = densityFunction(lightPos);

                    if(densityLight > 0.0){
                        float dl = densityLight * lightStep;
                        // 光照通过率也会被层层递减
                        transmittanceLight *= 1.0 - dl * _AbsorptionLight;
                        if(transmittanceLight < 0.01){
                            transmittanceLight = 0.0;
                            break;
                        }
                    }
                    lightPos += localLightStep;
                }
                // 当前点对整体透明度的影响
                color.a += _Color.a * (_Opacity * d * transmittance);
                // 光照贡献 = 场景主光颜色 * (亮度强度 * 密度 * 视线通过率 * 光线通过率)
                color.rgb += _LightColor0 * (_OpacityLight * d * transmittance * transmittanceLight);
            }

            color = clamp(color, 0.0, 1.0);
            localPos += localStep;

            if(!all(max(0.5 - abs(localPos), 0.0))) break;
        }
        return color;
    }
    ENDCG

    SubShader
    {
        Tags { "Queue" = "Transparent" "RenderType"="Transparent" }

        Pass
        {
            Cull Back
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha
            Lighting Off    //不参与光照

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            ENDCG
        }
    }
}
