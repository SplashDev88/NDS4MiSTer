#include "replay_video_capture.h"
#include <cassert>
#include <iostream>

int main(){
 unsigned checks=0;
 for(const auto& text:{"","1",":2","1:","1:2,","1:2,1:3","2:2","3:2","0:6","-1:2","0:2:3","1:2,x"}){
  bool failed=false;try{ReplayVideoCapture c;c.Load(text,5);}catch(const std::exception&){failed=true;}
  assert(failed);++checks;
 }
 ReplayVideoCapture c(2);c.Load("3:4,1:2",5);
 std::ostringstream pixels,index;c.Header(index);
 const char a[2]={'A','B'},b[2]={'C','D'};
 for(unsigned f=0;f<5;++f)c.Frame(f,a,b,f+1,11,22,pixels,index);
 c.Finish(pixels,index);
 assert(pixels.str()=="ABCDABCD");++checks;
 assert(index.str()=="frame,first_audio_sample,audio_samples,hash_top,hash_bottom\n1,1,2,11,22\n3,6,4,11,22\n");++checks;
 bool failed=false;try{c.Frame(5,a,b,1,11,22,pixels,index);}catch(const std::exception&){failed=true;}
 assert(failed);++checks;
 ReplayVideoCapture partial(2);partial.Load("0:1",2);
 partial.Frame(0,a,b,1,11,22,pixels,index);
 failed=false;try{partial.Finish(pixels,index);}catch(const std::exception&){failed=true;}
 assert(failed);++checks;
 ReplayVideoCapture skipped(2);skipped.Load("0:2",2);
 failed=false;try{skipped.Frame(1,a,b,1,11,22,pixels,index);}catch(const std::exception&){failed=true;}
 assert(failed);++checks;
 std::cout<<checks<<" video capture checks passed\n";
}
