// 体积云 无光照
Shader "VolumeCloud/2-CloudUnlit"
{
    Properties
    {
        _Color("Color", Color) = (1, 1, 1, 1)
        _Intensity("Intensity", Range(0, 1)) = 0.1
        _Loop("Loop", Range(0, 128)) = 32

        [Header(Cloud)]
        _NoiseScale("NoiseScale", Range(0, 100)) = 5
        _Radius("Radius", Range(0, 2)) = 1.0
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
    float _Intensity;
    int _Loop;

    float _NoiseScale;
    float _Radius;

    // ref. https : //www.shadertoy.com / view / lss3zr
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
    // - 自然，层次丰富的噪声，用于云、火焰、水面模拟
    inline float fbm(float3 p){
        float3x3 m = float3x3(
        + 0.00, + 0.80, + 0.60,
        - 0.80, + 0.36, - 0.48,
        - 0.60, - 0.48, + 0.64);
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

        float3 localPos = mul(unity_WorldToObject, float4(worldPos, 1.0));
        float3 localDir = UnityWorldToObjectDir(worldDir);
        float3 localStep = localDir * step;

        // 为每条射线加入一个“起始偏移”，避免 banding 条纹伪影
        float jitter = hash(localPos.x + localPos.y * 10 + localPos.z * 100 + _Time.x);
        localPos += localStep * jitter;

        float alpha = 0.0;

        for(int i = 0; i < _Loop; ++ i){
            float density = densityFunction(localPos);

            if(density > 0.001){
                alpha += (1.0 - alpha) * density * _Intensity;
            }

            localPos += localStep;
            if(! all(max(0.5 - abs(localPos), 0.0))) break;
        }
        float4 color = _Color;
        color.a *= alpha;
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
            Lighting Off //不参与光照

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            ENDCG
        }
    }
}
