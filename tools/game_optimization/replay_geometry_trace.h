// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "NDS4MiSTer_2DTrace.h"
#include <cstring>
#include <functional>
#include <stdexcept>
#include <vector>

// Consume the existing trace byte stream, whose records may span sink calls.
// Only geometry records reach the observer; all other payloads remain opaque.
class ReplayGeometryTrace {
public:
 using Observer = std::function<void(melonDS::NDS4MiSTer::Trace2DRecordType,
                                     const unsigned char*, size_t)>;
 explicit ReplayGeometryTrace(Observer observer) : observer_(std::move(observer)) {}
 void Push(const void* data, size_t size) {
  const auto* bytes=static_cast<const unsigned char*>(data);
  while(size) {
   const size_t needed=expected_ ? expected_ : sizeof(Header);
   const size_t take=std::min(size,needed-pending_.size());
   pending_.insert(pending_.end(),bytes,bytes+take);bytes+=take;size-=take;
   if(!expected_ && pending_.size()==sizeof(Header)) {
    Header header;std::memcpy(&header,pending_.data(),sizeof(header));
    if(header.Size<sizeof(Header))throw std::runtime_error("Invalid trace record size");
    expected_=header.Size;
   }
   if(expected_ && pending_.size()==expected_) {
    Header header;std::memcpy(&header,pending_.data(),sizeof(header));
    using namespace melonDS::NDS4MiSTer;
    const auto kind=static_cast<Trace2DRecordType>(header.Type);
    size_t required=0;
    if(kind==Trace2DRecordType::GeometryCommand)required=sizeof(Trace2DGeometryCommandPacket);
    if(kind==Trace2DRecordType::GeometryFrame)required=sizeof(Trace2DGeometryFramePacket);
    if(kind==Trace2DRecordType::GeometryRegister)required=sizeof(Trace2DGeometryRegisterPacket);
    if(required) {
     if(expected_!=required)throw std::runtime_error("Invalid geometry record size");
     observer_(kind,pending_.data(),pending_.size());++records;
    }
    pending_.clear();expected_=0;
   }
  }
 }
 void Finish() const {
  if(!pending_.empty()||expected_)throw std::runtime_error("Truncated trace record");
  if(!records)throw std::runtime_error("No geometry records observed");
 }
 size_t records=0;
private:
 using Header=melonDS::NDS4MiSTer::Trace2DRecordHeader;
 Observer observer_;
 std::vector<unsigned char> pending_;
 size_t expected_=0;
};
