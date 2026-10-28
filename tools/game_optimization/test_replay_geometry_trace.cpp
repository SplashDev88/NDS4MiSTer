// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay_geometry_trace.h"
#include <cassert>
#include <iostream>
using namespace melonDS::NDS4MiSTer;
int main() {
 Trace2DGeometryCommandPacket command{{5,sizeof(Trace2DGeometryCommandPacket)},123,456,0x20,{},0x789};
 Trace2DRecordHeader opaque{99,12};
 std::vector<unsigned char> bytes(12,0xff);
 std::memcpy(bytes.data(),&opaque,sizeof(opaque));
 const auto* p=reinterpret_cast<const unsigned char*>(&command);
 bytes.insert(bytes.end(),p,p+sizeof(command));
 bytes.insert(bytes.end(),p,p+sizeof(command));
 // Exercise boundaries inside headers/payloads and coalesced opaque records.
 for(size_t stride=1;stride<=bytes.size();++stride) {
  unsigned seen=0;
  ReplayGeometryTrace trace([&](auto kind,const unsigned char* data,size_t size){
   assert(kind==Trace2DRecordType::GeometryCommand && size==sizeof(command));
   assert(std::memcmp(data,&command,size)==0);++seen;
  });
  for(size_t i=0;i<bytes.size();i+=stride)trace.Push(bytes.data()+i,std::min(stride,bytes.size()-i));
  trace.Finish();assert(seen==2 && trace.records==2);
 }
 auto fails=[](auto fn){bool failed=false;try{fn();}catch(const std::runtime_error&){failed=true;}assert(failed);};
 fails([&]{ReplayGeometryTrace t([](auto,auto,auto){});t.Finish();});
 fails([&]{ReplayGeometryTrace t([](auto,auto,auto){});t.Push(p,sizeof(command)-1);t.Finish();});
 fails([&]{ReplayGeometryTrace t([](auto,auto,auto){});Trace2DRecordHeader h{5,3};t.Push(&h,sizeof(h));});
 fails([&]{ReplayGeometryTrace t([](auto,auto,auto){});Trace2DRecordHeader h{5,4};t.Push(&h,sizeof(h));});
 for(auto kind:{Trace2DRecordType::GeometryFrame,Trace2DRecordType::GeometryRegister}) {
  const size_t n=kind==Trace2DRecordType::GeometryFrame?sizeof(Trace2DGeometryFramePacket):sizeof(Trace2DGeometryRegisterPacket);
  std::vector<unsigned char> b(n,0);Trace2DRecordHeader h{static_cast<melonDS::u16>(kind),static_cast<melonDS::u16>(n)};
  std::memcpy(b.data(),&h,sizeof(h));unsigned seen=0;ReplayGeometryTrace t([&](auto k,auto,size_t s){assert(k==kind&&s==n);++seen;});t.Push(b.data(),b.size());t.Finish();assert(seen==1);
 }
 std::cout<<"geometry stream fragmentation and failure checks passed\n";
}
