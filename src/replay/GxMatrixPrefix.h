// SPDX-License-Identifier: GPL-3.0-or-later
// Matrix/stack semantics derived from melonDS GPU3D.cpp.
// Copyright 2016-2026 melonDS team. See third_party/melonDS for its license.
// This private prefix owner never draws or accesses the renderer's state.
#pragma once

#include "types.h"
#include "GxBoxTest.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <vector>

namespace melonDS {
// Reuse the oracle's exact fixed-point arithmetic, including rounding order.
void MatrixLoadIdentity(s32*);
void MatrixLoad4x4(s32*, s32*);
void MatrixLoad4x3(s32*, s32*);
void MatrixMult4x4(s32*, s32*);
void MatrixMult4x3(s32*, s32*);
void MatrixMult3x3(s32*, s32*);
void MatrixScale(s32*, s32*);
void MatrixTranslate(s32*, s32*);
}

namespace nds4mister::replay {

class GxMatrixPrefix {
public:
    using Matrix = std::array<melonDS::s32, 16>;
    GxMatrixPrefix() { reset(); }
    void reset()
    {
        for (auto* m : {&projection_, &position_, &vector_, &texture_})
            melonDS::MatrixLoadIdentity(m->data());
        projection_stack_ = {}; texture_stack_ = {};
        position_stack_ = {}; vector_stack_ = {};
        mode_ = projection_sp_ = position_sp_ = texture_sp_ = 0;
        partial_count_ = partial_tag_ = status_ = 0;
        params_ = {}; deferred_.clear(); deferred_head_ = 0; deferred_cost_ = 0;
        enabled_ = true; swapped_ = false; valid_ = true;
        polygon_attr_ = current_polygon_attr_ = 0;
        invalid_reason_ = invalid_tag_ = invalid_partial_ = 0;
        deferred_peak_ = 0;
    }
    bool valid() const { return valid_; }
    unsigned invalid_reason() const { return invalid_reason_; }
    unsigned invalid_tag() const { return invalid_tag_; }
    unsigned invalid_partial() const { return invalid_partial_; }
    unsigned deferred_peak() const { return deferred_peak_; }
    void invalidate() { valid_ = false; deferred_.clear(); deferred_head_ = 0; deferred_cost_ = 0; }

    [[gnu::always_inline]] inline void command(std::uint8_t tag, std::uint32_t value)
    {
        if (!valid_ || !enabled_) return;
        // COLOR/NORMAL/TEXCOORD and the single-word vertex commands do not
        // affect this matrix/status shadow. The renderer still replays them.
        // Skip only a fully settled command: pending matrix parameters must
        // still reject a different tag, and work behind SWAP retains its
        // ordered execution and bounded deferred-cost accounting. VTX_16
        // (0x23) has two parameters and must retain its partial/busy state.
        if (tag >= 0x20 && tag <= 0x28 && tag != 0x23 &&
            !swapped_ && partial_count_ == 0 &&
            deferred_head_ == deferred_.size())
            return;
        command_ordered(tag, value);
    }

    void vblank()
    {
        if (!valid_ || !enabled_) return;
        swapped_ = false;
    }
    // VBlank releases SWAP; execution time comes from the next ordered GX
    // command/query, exactly as in the existing replay owner.
    void settle() { if (enabled_ && !swapped_) drain(); }

    void power(std::uint32_t address, std::uint32_t value, unsigned bytes)
    {
        // Only POWCNT1's low byte controls the geometry engine. Writes to its
        // screen-swap/high byte must not spuriously enable or disable it.
        if (address == 0x04000304u && bytes != 0) {
            enabled_ = (value & 8u) != 0;
        }
    }

    void gxstat(std::uint32_t address, std::uint32_t value, unsigned bytes)
    {
        std::uint32_t word = 0, mask = 0;
        for (unsigned i = 0; i < bytes; ++i) {
            if (address + i < 0x04000600u || address + i > 0x04000603u) continue;
            const auto shift = 8u * (address + i - 0x04000600u);
            word |= ((value >> (8u * i)) & 255u) << shift;
            mask |= 255u << shift;
        }
        if (word & 0x8000u) {
            status_ &= ~0x8000u;
            projection_sp_ = texture_sp_ = 0;
        }
        if (mask & 0xc0000000u)
            status_ = (status_ & ~0xc0000000u) | (word & 0xc0000000u);
    }

    Matrix clip() const
    {
        auto result = projection_;
        auto position = position_;
        melonDS::MatrixMult4x4(result.data(), position.data());
        return result;
    }
    const Matrix& vector() const { return vector_; }
    std::uint32_t status() const
    {
        return status_ | 0x06000000u | ((position_sp_ & 31u) << 8) |
            ((projection_sp_ & 1u) << 13) |
            ((partial_count_ && (partial_tag_ == 0x70 || partial_tag_ == 0x71)) ? 1u : 0u) |
            ((swapped_ || deferred_head_ != deferred_.size() || partial_count_) ?
                0x08000000u : 0u);
    }

private:
    // Keep the ordered/deferred path out of the settled-command shortcut.
    // On ARM32 its stack/register setup otherwise runs even for ignored
    // single-word vertex commands. Only command() calls this after checking
    // enabled/valid state; all deferred ordering and accounting is unchanged.
    [[gnu::noinline]] void command_ordered(std::uint8_t tag, std::uint32_t value)
    {
        if (!swapped_) drain();
        if (swapped_ || deferred_head_ != deferred_.size()) {
            // Consecutive SWAPs can keep a live tail across many VBlanks.
            // Entries before head already executed and no longer consume
            // the pending-work budget. Reclaim them only at the storage cap
            // to avoid moving the live tail on every command/frame.
            if (deferred_.size() == MaxDeferred && deferred_head_ != 0) {
                deferred_.erase(deferred_.begin(),
                    deferred_.begin() + deferred_head_);
                deferred_head_ = 0;
            }
            // A bounded fallback to the existing replay owner is preferable
            // to guessing after an unsupported/malformed command sequence.
            if (deferred_.size() == MaxDeferred) {
                invalid_reason_ = 1; invalid_tag_ = tag; invalidate(); return;
            }
            const auto cost = deferred_cost(tag);
            if (deferred_cost_ + cost > MaxDeferredCost) {
                invalid_reason_ = 3; invalid_tag_ = tag; invalidate(); return;
            }
            deferred_.push_back({tag, value});
            deferred_cost_ += cost;
            deferred_peak_ = std::max(deferred_peak_,
                unsigned(deferred_.size() - deferred_head_));
        } else execute(tag, value);
    }

    struct Command { std::uint8_t tag; std::uint32_t value; };
    // Count execution work separately from parameter words. DS startup may
    // initialize all 32 matrix-stack entries behind SWAP, exceeding 512 words
    // without approaching one query's 32768 geometry-clock allowance.
    // Allow 16 cycles for simple state/attribute commands, 128 for other
    // ordinary commands, 256 for multiword matrices, and 512 for SWAP/BOX_TEST.
    // These exceed the vendored command/pipeline costs; treating every
    // texcoord as a vertex falsely rejects FFT A2's startup draw bursts.
    // Reserve 2768 cycles
    // for the prior SWAP's 325-cycle remainder and incomplete boundary work.
    // This is an eligibility bound, not an alternative geometry timing model.
    static constexpr std::size_t MaxDeferred = 4096;
    static constexpr unsigned MaxDeferredCost = 30000;
    static unsigned parameters(std::uint8_t tag)
    {
        switch (tag) {
        case 0x16: case 0x18: return 16;
        case 0x17: case 0x19: return 12;
        case 0x1a: return 9;
        case 0x1b: case 0x1c: case 0x70: return 3;
        case 0x23: case 0x71: return 2;
        case 0x34: return 32;
        default: return 1;
        }
    }
    static unsigned deferred_cost(std::uint8_t tag)
    {
        // GPU3D's Delayed4/6/8 helpers wait at most 8 cycles: both normal
        // and vertex pipelines are bounded by 7. Material writes add 3,
        // light color adds 1, and lighting adds at most 4 (four lights).
        // None of these commands waits for polygon completion. Keep the
        // conservative bounds below for vertices and matrix/stack work.
        switch (tag) {
        case 0x00: case 0x10: case 0x20: case 0x21: case 0x22:
        case 0x29: case 0x2a: case 0x2b: case 0x30: case 0x31:
        case 0x33: case 0x41: case 0x60:
            return 16;
        default: break;
        }
        const auto count = parameters(tag);
        const auto cycles = tag == 0x50 || tag == 0x70 ? 512u :
            tag >= 0x16 && tag <= 0x1c ? 256u : 128u;
        return (cycles + count - 1u) / count;
    }
    void drain()
    {
        while (valid_ && enabled_ && !swapped_ && deferred_head_ < deferred_.size()) {
            const auto cmd = deferred_[deferred_head_++];
            deferred_cost_ -= deferred_cost(cmd.tag);
            execute(cmd.tag, cmd.value);
        }
        if (deferred_head_ == deferred_.size()) { deferred_.clear(); deferred_head_ = 0; }
    }
    void execute(std::uint8_t tag, std::uint32_t value)
    {
        const auto count = parameters(tag);
        if (partial_count_ && partial_tag_ != tag) {
            invalid_reason_ = 2; invalid_tag_ = tag; invalid_partial_ = partial_tag_;
            invalidate(); return;
        }
        if (count > 1) {
            partial_tag_ = tag;
            params_[partial_count_++] = static_cast<melonDS::s32>(value);
            if (partial_count_ < count) return;
            partial_count_ = 0;
        } else params_[0] = static_cast<melonDS::s32>(value);

        auto& current = mode_ == 0 ? projection_ : mode_ == 3 ? texture_ : position_;
        switch (tag) {
        case 0x10: mode_ = value & 3u; break;
        case 0x11:
            if (mode_ == 0) {
                if (projection_sp_) status_ |= 0x8000u;
                projection_stack_ = projection_; projection_sp_ ^= 1u;
            } else if (mode_ == 3) {
                if (texture_sp_) status_ |= 0x8000u;
                texture_stack_ = texture_; texture_sp_ ^= 1u;
            } else {
                if (position_sp_ > 30) status_ |= 0x8000u;
                position_stack_[position_sp_ & 31u] = position_;
                vector_stack_[position_sp_ & 31u] = vector_;
                position_sp_ = (position_sp_ + 1u) & 63u;
            }
            break;
        case 0x12:
            if (mode_ == 0) {
                if (!projection_sp_) status_ |= 0x8000u;
                projection_sp_ ^= 1u; projection_ = projection_stack_;
            } else if (mode_ == 3) {
                if (!texture_sp_) status_ |= 0x8000u;
                texture_sp_ ^= 1u; texture_ = texture_stack_;
            } else {
                position_sp_ = (position_sp_ - value) & 63u;
                if (position_sp_ > 30) status_ |= 0x8000u;
                position_ = position_stack_[position_sp_ & 31u];
                vector_ = vector_stack_[position_sp_ & 31u];
            }
            break;
        case 0x13:
            if (mode_ == 0) projection_stack_ = projection_;
            else if (mode_ == 3) texture_stack_ = texture_;
            else {
                const auto index = value & 31u;
                if (index > 30) status_ |= 0x8000u;
                position_stack_[index] = position_; vector_stack_[index] = vector_;
            }
            break;
        case 0x14:
            if (mode_ == 0) projection_ = projection_stack_;
            else if (mode_ == 3) texture_ = texture_stack_;
            else {
                const auto index = value & 31u;
                if (index > 30) status_ |= 0x8000u;
                position_ = position_stack_[index]; vector_ = vector_stack_[index];
            }
            break;
        case 0x15:
            melonDS::MatrixLoadIdentity(current.data());
            if (mode_ == 2) melonDS::MatrixLoadIdentity(vector_.data());
            break;
        case 0x16: matrix_op(melonDS::MatrixLoad4x4); break;
        case 0x17: matrix_op(melonDS::MatrixLoad4x3); break;
        case 0x18: matrix_op(melonDS::MatrixMult4x4); break;
        case 0x19: matrix_op(melonDS::MatrixMult4x3); break;
        case 0x1a: matrix_op(melonDS::MatrixMult3x3); break;
        case 0x1b: melonDS::MatrixScale(current.data(), params_.data()); break;
        case 0x1c: matrix_op(melonDS::MatrixTranslate); break;
        case 0x29: polygon_attr_ = value; break;
        case 0x40: current_polygon_attr_ = polygon_attr_; break;
        case 0x50: swapped_ = true; break;
        case 0x70:
            status_ = (status_ & ~2u) |
                (gx_box_test(clip(), params_.data(), (current_polygon_attr_ & 0x1000u)!=0) ? 2u : 0u);
            break;
        default: break; // Vertex/texture/lighting/test commands do not change matrices.
        }
    }
    void matrix_op(void (*op)(melonDS::s32*, melonDS::s32*))
    {
        auto& current = mode_ == 0 ? projection_ : mode_ == 3 ? texture_ : position_;
        op(current.data(), params_.data());
        if (mode_ == 2) op(vector_.data(), params_.data());
    }
    Matrix projection_, position_, vector_, texture_, projection_stack_, texture_stack_;
    std::array<Matrix, 32> position_stack_, vector_stack_;
    std::array<melonDS::s32, 32> params_ {};
    std::vector<Command> deferred_;
    std::size_t deferred_head_ = 0;
    unsigned deferred_cost_ = 0;
    unsigned mode_ = 0, projection_sp_ = 0, position_sp_ = 0, texture_sp_ = 0;
    unsigned partial_count_ = 0, partial_tag_ = 0;
    std::uint32_t status_ = 0;
    std::uint32_t polygon_attr_ = 0, current_polygon_attr_ = 0;
    unsigned invalid_reason_ = 0, invalid_tag_ = 0, invalid_partial_ = 0, deferred_peak_ = 0;
    bool enabled_ = true, swapped_ = false, valid_ = true;
};
}
