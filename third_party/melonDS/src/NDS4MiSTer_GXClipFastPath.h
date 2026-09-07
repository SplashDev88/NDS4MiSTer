#pragma once

#include <cstdint>
#include <limits>

namespace melonDS
{

// ClipAgainstPlane copies every 64-byte vertex through a temporary buffer for
// each of the Z, Y, and X planes, even when the polygon is already wholly
// inside the clip volume.  In that case its only other visible operation is
// forcing the low twelve color bits to one.  SubmitVertex and ClipSegment
// normally maintain that color invariant already.  Check both facts before
// bypassing the three unchanged copy/normalize passes; if either fact is not
// true, the original clipper remains authoritative.
template<typename VertexType>
inline bool NDS4MiSTerGXClipPolygonIsUnchanged(
    const VertexType* vertices,
    int nverts,
    int clipstart) noexcept
{
    if (clipstart < 0 || clipstart > nverts)
        return false;

    for (int i = 0; i < nverts; ++i)
    {
        const VertexType& vertex = vertices[i];
        const std::uint32_t normalizedColorBits =
            static_cast<std::uint32_t>(vertex.Color[0]) &
            static_cast<std::uint32_t>(vertex.Color[1]) &
            static_cast<std::uint32_t>(vertex.Color[2]) & 0xFFFu;
        if (normalizedColorBits != 0xFFFu)
            return false;

        // Strip-reused vertices before clipstart intentionally bypass the
        // plane tests in the original clipper as well.
        if (i < clipstart)
            continue;

        const std::int32_t w = vertex.Position[3];
        if (w == std::numeric_limits<std::int32_t>::min())
            return false;
        const std::int32_t negativeW = -w;

        if (vertex.Position[2] > w || vertex.Position[2] < negativeW ||
            vertex.Position[1] > w || vertex.Position[1] < negativeW ||
            vertex.Position[0] > w || vertex.Position[0] < negativeW)
            return false;
    }

    return true;
}

}
