#!/usr/bin/env python3
"""Pixel-level RTL oracle: capture-derived gains, alignment, timing and bypass."""
from fractions import Fraction
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = [[3,16,15,16],[1,17,17,16],[4,22,23,22],[2,16,16,16]]

def mask(scale):
    result = []
    for y in range(scale):
        row = []
        for x in range(scale):
            value = Fraction(0)
            for j in range(4):
                dy = max(0, min(Fraction(y+1,scale),Fraction(j+1,4))-max(Fraction(y,scale),Fraction(j,4)))
                for i in range(4):
                    dx = max(0, min(Fraction(x+1,scale),Fraction(i+1,4))-max(Fraction(x,scale),Fraction(i,4)))
                    value += REFERENCE[j][i]*dx*dy*scale*scale
            row.append(int(value+Fraction(1,2)))
        result.append(row)
    return result

def run(out):
    out.mkdir(parents=True,exist_ok=True)
    count=0
    with (out/'vectors.txt').open('w') as f:
        config=[1,2,256,192,1024,768,1920,1080] # enable, strength, source/image/raster
        def sample(rgb=0,expected=None,hs=0,vs=0,de=0,brd=1,ce=1,reset=0):
            nonlocal count
            values=[ce,reset,*config,rgb,hs,vs,de,brd,rgb if expected is None else expected]
            f.write(' '.join(f'{v:x}' for v in values)+'\n'); count+=1
        def start():
            for _ in range(12):sample()
            for _ in range(4):sample(vs=1)
            for _ in range(12):sample()
        def patch(scale,strength,seed=0,enabled=True):
            table=mask(scale) if scale>=2 else [[16]]
            # Odd-width borders, blanking, and CE stalls must not shift the cell.
            for y in range(2*scale):
                for _ in range(7):sample(rgb=0x384c70,de=1)
                for x in range(3*scale):
                    channels=[seed,255-seed,(seed*37)&255]
                    rgb=(channels[0]<<16)|(channels[1]<<8)|channels[2]
                    base=table[y%scale][x%scale]
                    coeff=64 if not enabled or strength==0 else (32+2*base if strength==1 else 4*base if strength==2 else max(0,5*base-16))
                    output=[min(255,(p*coeff+32)//64) for p in channels]
                    expected=(output[0]<<16)|(output[1]<<8)|output[2]
                    sample(rgb,expected,de=1,brd=0)
                    if x==scale and y==scale:sample(rgb,expected,de=1,brd=0,ce=0)
                for _ in range(5):sample(rgb=0x123456,de=1)
                for _ in range(9):sample(hs=1)
                for _ in range(4):sample()
        sample(reset=1)
        # Exhaust all RGB component levels at every phase/strength and scale.
        for s in range(2,6):
            for strength in range(4):
                config[:]=[1,strength,256,192,256*s,192*s,1920,1080]
                for value in range(256):start();patch(s,strength,value)
        # Actual beta18 canvas sizes: both layouts, gaps, FPS, both rotations,
        # plus single-screen source dimensions. Output grid is display-oriented.
        cases=0
        for rw,rh in [(1280,720),(1920,1080)]:
            for layout in range(4):
                for gap in [0,8,16,24]:
                    for fps in [0,6]:
                        w=512+gap if layout==0 else 256
                        h=(384+gap if layout==1 else 192)+fps
                        for rotation in range(3):
                            sw,sh=(w,h) if rotation==0 else (h,w)
                            s=min(rw//sw,rh//sh)
                            config[:]=[1,2,sw,sh,sw*s,sh*s,rw,rh]
                            start();patch(s,2,91,enabled=s>=2);cases+=1
        # Unsupported modes (including repeated 1440p), native/direct-video
        # enable gate, 1x, noninteger and differently scaled axes: exact bypass.
        for config_values in [
            [1,3,256,192,1792,1344,2560,1440],
            [1,3,256,192,1280,960,1280,1440],
            [1,3,256,192,1280,960,1920,1440],
            [0,3,256,192,1024,768,1920,1080],
            [1,3,256,192,256,192,1280,720],
            [1,3,256,192,1023,768,1920,1080],
            [1,3,256,192,1024,576,1920,1080],
            [1,3,256,192,1280,960,1280,720],
            [1,3,0,192,0,768,1920,1080],
            [1,3,256,0,1024,0,1920,1080],
            [1,3,4095,4095,4091,4091,1920,1080],
            [1,3,1,1,6,6,1920,1080],
        ]:
            config[:]=config_values;start();patch(4,3,183,enabled=False)
        # Setting changes wait for a frame boundary; geometry changes bypass
        # the rest of that frame, then restart with the new integer period.
        config[:]=[1,0,256,192,1024,768,1920,1080];start()
        config[1]=2
        for _ in range(12):sample()
        patch(4,0,157);start();patch(4,2,157)
        config[4:6]=[768,576]
        patch(3,2,53,enabled=False);start();patch(3,2,53)
        # Search progresses only on enabled clocks and uses the geometry
        # captured at VS. Changes during the search must not apply a mask to
        # the new rectangle before its own frame boundary.
        config[:]=[1,2,256,192,1280,960,1920,1080]
        sample(vs=1);sample(vs=1)
        for _ in range(9):sample(vs=1,ce=0)
        config[4:6]=[1024,768]
        for _ in range(12):sample()
        patch(4,2,111,enabled=False);start();patch(4,2,111)
        # Reset an unfinished scale search; following video remains bypassed
        # until a fresh frame latches its geometry and strength.
        sample(vs=1);sample(reset=1)
        for _ in range(12):sample()
        patch(4,2,97,enabled=False);start();patch(4,2,97)
        for _ in range(8):sample()
    tb=r'''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg ce=1,reset=1,en=0;reg[1:0]strength=0;
reg[11:0]sw=0,sh=0,iw=0,ih=0,rw=0,rh=0;
reg[23:0]din=0;reg hs=0,vs=0,de=0,brd=1;
wire[23:0]dout;wire ho,vo,deo;
nds_pixel_grid dut(clk,reset,ce,en,strength,sw,sh,iw,ih,rw,rh,din,hs,vs,de,brd,dout,ho,vo,deo);
reg[26:0]expected[0:3];reg[23:0]rgb_expected;
integer f,n,i,line=0,filled=0,checks=0;
initial begin
 f=$fopen("vectors.txt","r");if(!f)$fatal(1,"vectors missing");
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",ce,reset,en,strength,sw,sh,iw,ih,rw,rh,din,hs,vs,de,brd,rgb_expected);
  if(n!=16)$fatal(1,"bad vector %0d",line);line=line+1;
  if(reset)filled=0;
  else if(ce)begin
   for(i=3;i>0;i=i-1)expected[i]=expected[i-1];
   expected[0]={hs,vs,de,rgb_expected};filled=filled+1;
  end
  @(posedge clk);#1;
  if(filled>=4)begin
   if({ho,vo,deo,dout}!==expected[3])
    $fatal(1,"line %0d got=%h expected=%h scale=%d phase=%d,%d",line,{ho,vo,deo,dout},expected[3],dut.scale,dut.xphase,dut.yphase);
   checks=checks+1;
  end
 end
 $display("PASS %0d pixel/sync checks, all RGB values, strengths/scales, border and CE alignment, modes, frame changes",checks);
 $finish;
end
endmodule
'''
    (out/'tb.sv').write_text(tb)
    subprocess.run(['iverilog','-g2012','-Wall','-s','tb','-o',str(out/'sim'),str(ROOT/'rtl/nds_pixel_grid.sv'),str(out/'tb.sv')],check=True)
    r=subprocess.run(['vvp',str(out/'sim')],cwd=out,text=True,capture_output=True)
    (out/'test.log').write_text(r.stdout+r.stderr)
    print(r.stdout+r.stderr,end='');r.check_returncode()
    print(f'PASS {cases} layout/gap/FPS/rotation/resolution combinations; {count} input cycles')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    run(parser.parse_args().output.resolve())
