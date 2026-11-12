// SPDX-License-Identifier: GPL-3.0-or-later
// Frozen Beta11 CalculateLighting body from e47ee7e0; body SHA256 48355c6c7868fc46e2186c900250a4373f68c9efba271538f69ff128c5213e38
static void reference_lighting_beta11(GPU3D& g) {
    auto& TexParam=g.TexParam;
    auto& TexCoords=g.TexCoords;
    auto& RawTexCoords=g.RawTexCoords;
    auto& Normal=g.Normal;
    auto& TexMatrix=g.TexMatrix;
    auto& VecMatrix=g.VecMatrix;
    auto& MatEmission=g.MatEmission;
    auto& CurPolygonAttr=g.CurPolygonAttr;
    auto& LightDirection=g.LightDirection;
    auto& MatDiffuse=g.MatDiffuse;
    auto& LightColor=g.LightColor;
    auto& SpecRecip=g.SpecRecip;
    auto& UseShininessTable=g.UseShininessTable;
    auto& ShininessTable=g.ShininessTable;
    auto& MatSpecular=g.MatSpecular;
    auto& MatAmbient=g.MatAmbient;
    auto& VertexColor=g.VertexColor;
    auto& NormalPipeline=g.NormalPipeline;
    auto AddCycles=[&](s32 cycles) {g.AddCycles(cycles);};

    if ((TexParam >> 30) == 2)
    {
        TexCoords[0] = RawTexCoords[0] + (((s64)Normal[0]*TexMatrix[0] + (s64)Normal[1]*TexMatrix[4] + (s64)Normal[2]*TexMatrix[8]) >> 21);
        TexCoords[1] = RawTexCoords[1] + (((s64)Normal[0]*TexMatrix[1] + (s64)Normal[1]*TexMatrix[5] + (s64)Normal[2]*TexMatrix[9]) >> 21);
    }

    s32 normaltrans[3]; // should be 1 bit sign 10 bits frac
    normaltrans[0] = ((Normal[0]*VecMatrix[0] + Normal[1]*VecMatrix[4] + Normal[2]*VecMatrix[8]) << 9) >> 21;
    normaltrans[1] = ((Normal[0]*VecMatrix[1] + Normal[1]*VecMatrix[5] + Normal[2]*VecMatrix[9]) << 9) >> 21;
    normaltrans[2] = ((Normal[0]*VecMatrix[2] + Normal[1]*VecMatrix[6] + Normal[2]*VecMatrix[10]) << 9) >> 21;

    s32 c = 0;
    u32 vtxbuff[3] =
    {
        (u32)MatEmission[0] << 14,
        (u32)MatEmission[1] << 14,
        (u32)MatEmission[2] << 14
    };
    for (int i = 0; i < 4; i++)
    {
        if (!(CurPolygonAttr & (1<<i)))
            continue;

        // (credit to azusa for working out most of the details of the diff. algorithm, and essentially the entire spec. algorithm)
        
        // calculate dot product
        // bottom 9 bits are discarded after multiplying and before adding
        s32 dot = ((LightDirection[i][0]*normaltrans[0]) >> 9) +
                  ((LightDirection[i][1]*normaltrans[1]) >> 9) +
                  ((LightDirection[i][2]*normaltrans[2]) >> 9);

        s32 shinelevel;
        if (dot > 0) 
        {
            // -- diffuse lighting --
            
            // convert dot to signed 11 bit int
            // then we truncate the result of the multiplications to an unsigned 20 bits before adding to the vtx color
            s32 diffdot = (dot << 21) >> 21;
            vtxbuff[0] += (MatDiffuse[0] * LightColor[i][0] * diffdot) & 0xFFFFF;
            vtxbuff[1] += (MatDiffuse[1] * LightColor[i][1] * diffdot) & 0xFFFFF;
            vtxbuff[2] += (MatDiffuse[2] * LightColor[i][2] * diffdot) & 0xFFFFF;

            // -- specular lighting --
        
            // reuse the dot product from diffuse lighting
            dot += normaltrans[2];

            // convert to s11, then square it, and truncate to 10 bits
            dot = (dot << 21) >> 21;
            dot = ((dot * dot) >> 10) & 0x3FF;

            // multiply dot and reciprocal, the subtract '1'
            shinelevel = ((dot * SpecRecip[i]) >> 8) - (1<<9);

            if (shinelevel < 0) shinelevel = 0;
            else
            {
                // sign extend to convert to signed 14 bit integer
                shinelevel = (shinelevel << 18) >> 18;
                if (shinelevel < 0) shinelevel = 0; // for some reason there seems to be a redundant check for <0?
                else if (shinelevel > 0x1FF) shinelevel = 0x1FF;
            }
        }
        else shinelevel = 0;

        // convert shinelevel to use for lookup in the shininess table if enabled.
        if (UseShininessTable)
        {
            shinelevel >>= 2;
            shinelevel = ShininessTable[shinelevel];
            shinelevel <<= 1;
        }

        // Note: ambient seems to be a plain bitshift
        vtxbuff[0] += ((MatSpecular[0] * shinelevel) + (MatAmbient[0] << 9)) * LightColor[i][0];
        vtxbuff[1] += ((MatSpecular[1] * shinelevel) + (MatAmbient[1] << 9)) * LightColor[i][1];
        vtxbuff[2] += ((MatSpecular[2] * shinelevel) + (MatAmbient[2] << 9)) * LightColor[i][2];

        c++;
    }

    VertexColor[0] = (vtxbuff[0] >> 14 > 31) ? 31 : (vtxbuff[0] >> 14);
    VertexColor[1] = (vtxbuff[1] >> 14 > 31) ? 31 : (vtxbuff[1] >> 14);
    VertexColor[2] = (vtxbuff[2] >> 14 > 31) ? 31 : (vtxbuff[2] >> 14);

    if (c < 1) c = 1;
    NormalPipeline = 7;
    AddCycles(c);
}
