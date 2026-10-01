// SPDX-License-Identifier: GPL-3.0-or-later
#include "ScopedQueryPriority.h"
#include <iostream>
#include <string_view>

using nds4mister::replay::ScopedQueryPriority;
using nds4mister::replay::QueryPriorityBackend;
void require(bool ok) { if (!ok) throw std::runtime_error("query priority invariant failed"); }
struct Fake {
    bool allow=true,raised=false;
    unsigned entries=0,exits=0,clocks=0;
    std::uint64_t time=100;
    bool elevate() { ++entries; raised=allow;return allow; }
    void restore() noexcept { ++exits;raised=false; }
    std::uint64_t now_us() noexcept { ++clocks;return time; }
};

int main(int argc,char** argv)
try {
    {
        Fake f;
        { ScopedQueryPriority<Fake> guard(f,false);guard.checkpoint();guard.release(); }
        require(!f.entries && !f.exits && !f.clocks);
    }
    {
        Fake f;
        { ScopedQueryPriority<Fake> guard(f,true);require(f.raised);guard.release();require(!f.raised);guard.release(); }
        require(f.entries==1 && f.exits==1);
    }
    {
        Fake f;
        try { ScopedQueryPriority<Fake> guard(f,true);throw std::runtime_error("prefix validation failure"); }
        catch (const std::runtime_error&) {}
        require(f.entries==1 && f.exits==1 && !f.raised);
    }
    {
        Fake f;
        auto early=[&] { ScopedQueryPriority<Fake> guard(f,true);return 7; };
        require(early()==7 && f.exits==1 && !f.raised);
    }
    {
        Fake f;
        { ScopedQueryPriority<Fake> guard(f,true);
          f.time+=1999;guard.checkpoint();require(guard.active());
          ++f.time;guard.checkpoint();require(!guard.active() && !f.raised);
          f.time+=10000;guard.checkpoint(); }
        require(f.entries==1 && f.exits==1);
    }
    {
        Fake f;f.allow=false;
        { ScopedQueryPriority<Fake> guard(f,true);require(!guard.active());guard.checkpoint(); }
        require(f.entries==1 && !f.exits && !f.clocks);
    }
    std::cout << "SCOPED_QUERY_PRIORITY_PASS disabled=1 restore=1 exception=1 early_return=1 budget=1 unavailable=1\n";
    if (argc==2 && std::string_view(argv[1])=="--native-scheduling") {
#ifdef __linux__
        int original_policy=0; sched_param original {};
        require(pthread_getschedparam(pthread_self(),&original_policy,&original)==0);
        require(original_policy==SCHED_OTHER);
        for (bool fail : {false,true}) {
            QueryPriorityBackend backend;
            try {
                ScopedQueryPriority guard(backend,true);
                int policy=0;sched_param p {};
                require(pthread_getschedparam(pthread_self(),&policy,&p)==0);
                require(policy==SCHED_FIFO && p.sched_priority==sched_get_priority_min(SCHED_FIFO)+1);
                if (fail) throw 7;
            } catch (int code) { require(code==7); }
            int policy=0;sched_param p {};
            require(pthread_getschedparam(pthread_self(),&policy,&p)==0);
            require(policy==original_policy && p.sched_priority==original.sched_priority);
        }
        std::cout << "SCOPED_QUERY_NATIVE_PASS normal_restore=1 exception_restore=1\n";
#else
        throw std::runtime_error("native scheduling test requires Linux");
#endif
    } else require(argc==1);
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n';return 1; }
