#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthesize the full MiSTer shell with observable component checkpoint ports.

This is an area feasibility experiment, NOT a functional checkpoint transport.
Only the frozen generated copy is instrumented. Raw virtual pins deliberately
keep capture, restore, validation and existing acquisition logic observable.
They are not synchronized host controls and must never be deployed. Missing
RAM/cache serializers, renderer ownership and host transport remain uncosted.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

PROJECT = Path('fpga/mister_nitro_console_island')
PORTS_SV = 'input wire [95:0] cp_area_in, output wire [127:0] cp_area_out,\n'
PORTS_VHDL = ('cp_area_in : in std_logic_vector(95 downto 0);\n'
              '      cp_area_out : out std_logic_vector(127 downto 0);\n      ')
COMPONENTS = [
    (2, 'iirq9', 2), (3, 'iirq7', 2), (4, 'itimer9', 4),
    (5, 'itimer7', 4), (6, 'iipc', 6), (7, 'idma9', 6),
    (8, 'idma7', 6), (9, 'isound', 9), (10, 'ispi', 4),
    (11, 'icard', 5), (12, 'isyscnt', 3), (13, 'irtc', 4),
    (14, 'itiming', 3), (15, 'registers', 3),
    (16, 'igpu2d_b_register_shadow', 3), (17, 'ih3d_events', 3),
    (18, 'igx_readback', 3), (19, 'ih3d_gx', 1),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'Expected exactly one occurrence: {old!r}')
    return text.replace(old, new, 1)


def edit(root, path, transform):
    p = root / path
    p.write_text(transform(p.read_text()))


def inject_vhdl_port(text):
    entity_text = text[:re.search(r'^architecture\b', text, re.M | re.I).start()]
    matches = list(re.finditer(r'(^\s*port\s*\(\s*)', entity_text, re.M))
    if len(matches) != 1:
        raise ValueError('Expected one VHDL entity port list')
    m = matches[0]
    return text[:m.end()] + PORTS_VHDL + text[m.end():]


def instance(text, label, ports, generic=None):
    """Add named associations to one VHDL instance, failing on source drift."""
    pattern = rf'\b{label}\s*:\s*entity\s+work\.\w+\b'
    matches = list(re.finditer(pattern, text, re.I))
    if len(matches) != 1:
        raise ValueError(f'Expected one instance: {label}')
    start = matches[0].end()
    port = re.search(r'\bport\s+map\s*\(', text[start:], re.I)
    if port is None:
        raise ValueError(label)
    pos = start + port.end()
    prefix = text[:pos]
    if generic:
        between = text[start:pos]
        if generic.split('=>')[0].strip() not in between:
            gm = re.search(r'\bgeneric\s+map\s*\(', between, re.I)
            if gm:
                at = start + gm.end()
                prefix = text[:at] + generic + ', ' + text[at:pos]
            else:
                at = start + port.start()
                prefix = text[:at] + 'generic map (' + generic + ')\n   ' + text[at:pos]
    return prefix + '\n      ' + ports + ',\n      ' + text[pos:]


def instrument_console(text):
    text = inject_vhdl_port(text)
    # The release has this single positional instance; normalize only in copy.
    text = once(text, 'port map (clk1x, resetCpu, io_bus9, g2d_wired_out, g2d_wired_done);',
                'port map (clk => clk1x, reset => resetCpu, gb_bus => io_bus9, '
                'wired_out => g2d_wired_out, wired_done => g2d_wired_done);')
    declaration = '''
   -- Generated area probe only: raw virtual pins are NOT a host protocol.
   type cp_area_words is array(0 to 19) of std_logic_vector(31 downto 0);
   signal cp_area_data : cp_area_words;
   signal cp_area_valid, cp_area_ready, cp_area_error : std_logic_vector(19 downto 0);
   signal cp_area_restore, cp_area_write : std_logic_vector(19 downto 0);
   signal cp_area_sound_write_ready : std_logic;
'''
    text = once(text, 'architecture arch of nds_nitro_console_top is',
                'architecture arch of nds_nitro_console_top is' + declaration)
    # Insert after architecture declarations, not a function-local begin.
    top_begin = re.search(r'^begin\s*$', text, re.M)
    if top_begin is None:
        raise ValueError('Missing architecture begin')
    logic = '''
   g_area_select: for n in 0 to 19 generate
      cp_area_restore(n) <= cp_area_in(46);
      cp_area_write(n) <= cp_area_in(47) when unsigned(cp_area_in(4 downto 0)) = n else '0';
   end generate;
   cp_area_data(0) <= checkpoint_data9; cp_area_data(1) <= checkpoint_data7;
   cp_area_valid(0) <= checkpoint_valid9; cp_area_valid(1) <= checkpoint_valid7;
   cp_area_ready(1 downto 0) <= "00"; cp_area_error(1 downto 0) <= "00";
   process(all)
      variable selected : natural;
   begin
      selected := to_integer(unsigned(cp_area_in(4 downto 0)));
      cp_area_out <= (others => '0');
      if selected < 20 then
         cp_area_out(31 downto 0) <= cp_area_data(selected);
         cp_area_out(32) <= cp_area_valid(selected);
         cp_area_out(33) <= cp_area_ready(selected);
         cp_area_out(34) <= cp_area_error(selected);
      end if;
      cp_area_out(35) <= cp_area_sound_write_ready;
      cp_area_out(36) <= checkpoint_ready;
      cp_area_out(37) <= checkpoint_busy;
      cp_area_out(38) <= checkpoint_pair_paused;
      cp_area_out(39) <= checkpoint_timed_out;
      cp_area_out(40) <= checkpoint_release_stalled;
      cp_area_out(41) <= checkpoint_lease_expired;
      cp_area_out(42) <= checkpoint_owner_request;
      cp_area_out(43) <= checkpoint_local_idle;
      cp_area_out(44) <= checkpoint_read_ready;
      cp_area_out(45) <= checkpoint_read_done;
      cp_area_out(46) <= checkpoint_read_error;
      cp_area_out(78 downto 47) <= std_logic_vector(checkpoint_epoch);
      cp_area_out(110 downto 79) <= checkpoint_read_data;
   end process;
'''
    text = text[:top_begin.end()] + logic + text[top_begin.end():]
    for number, label, width in COMPONENTS:
        ports = f'''checkpoint_address => unsigned(cp_area_in({4+width} downto 5)),
      checkpoint_data => cp_area_data({number}), checkpoint_valid => cp_area_valid({number}),
      checkpoint_restore => cp_area_restore({number}), checkpoint_write => cp_area_write({number}),
      checkpoint_write_data => cp_area_in(45 downto 14),
      checkpoint_restore_ready => cp_area_ready({number}), checkpoint_restore_error => cp_area_error({number})'''
        if number == 9:
            ports += ', checkpoint_write_ready => cp_area_sound_write_ready'
        if number == 18:
            ports += ', checkpoint_cache_ready => cp_area_in(84)'
        generic = None if number == 17 else 'EXPERIMENTAL_CHECKPOINT => CHECKPOINT_CPU_ENABLE'
        text = instance(text, label, ports, generic)
    # The acquisition coordinator withdraws its hold on reset. A restore-only
    # hold must therefore be independent, or reset+stop guarded serializers
    # are unreachable and synthesis can silently undercount the write cone.
    for old, new in [
        ('checkpoint_stop => checkpoint_hold_request',
         'checkpoint_stop => checkpoint_hold_request or cp_area_in(46)'),
        ('checkpoint_stop => checkpoint_card_stop',
         'checkpoint_stop => checkpoint_card_stop or cp_area_in(46)'),
        ('checkpoint_request => checkpoint_rtc_request',
         'checkpoint_request => checkpoint_rtc_request or cp_area_in(46)'),
        ('checkpoint_request => checkpoint_hold_request',
         'checkpoint_request => checkpoint_hold_request or cp_area_in(46)'),
        ('checkpoint_timing_stopped and checkpoint_fabric1_idle,',
         "checkpoint_timing_stopped and checkpoint_fabric1_idle) or cp_area_in(46),"),
        ('checkpoint_producers_stopped => checkpoint_cpus_observed and checkpoint_dma_stopped and',
         'checkpoint_producers_stopped => (checkpoint_cpus_observed and checkpoint_dma_stopped and'),
    ]:
        if old not in text:
            raise ValueError('Restore hold connection not found: '+old)
        text = text.replace(old,new)
    for number in (0, 1):
        label = 'icpu9' if number == 0 else 'icpu7'
        text = instance(text, label, f'checkpoint_restore => cp_area_restore({number})')
    # Preserve both the actual read-only coordinator and the complete write cone.
    old = "            cpu_save9.rst <= '0'; cpu_save7.rst <= '0';\n         end if;"
    new = old + '''
         if cp_area_in(46) = '1' then
            cpu_save9.Adr <= std_logic_vector(resize(unsigned(cp_area_in(12 downto 5)),proc_busadr));
            cpu_save7.Adr <= std_logic_vector(resize(unsigned(cp_area_in(12 downto 5)),proc_busadr));
            cpu_save9.Din <= cp_area_in(45 downto 14); cpu_save7.Din <= cp_area_in(45 downto 14);
            cpu_save9.ena <= cp_area_write(0); cpu_save7.ena <= cp_area_write(1);
            cpu_save9.rnw <= '0'; cpu_save7.rnw <= '0';
            cpu_save9.bEna <= "1111"; cpu_save7.bEna <= "1111";
            cpu_save9.rst <= '0'; cpu_save7.rst <= '0';
         end if;'''
    return once(text, old, new)


def instrument(root):
    for path, module in [(PROJECT/'sys/sys_top.v', 'sys_top'),
                         (PROJECT/'NDS4MiSTer.sv', 'emu'),
                         (Path('rtl/nds_nitro_console_island.sv'), 'nds_nitro_console_island')]:
        edit(root, path, lambda s, m=module: re.sub(
            rf'(module {m}\s*\(\s*)', lambda x: x[1]+PORTS_SV, s, count=1))
    connections = '.cp_area_in(cp_area_in), .cp_area_out(cp_area_out),\n'
    edit(root, PROJECT/'sys/sys_top.v', lambda s: once(s, 'emu emu\n(', 'emu emu\n('+connections))
    edit(root, PROJECT/'NDS4MiSTer.sv', lambda s: once(s, 'nds_nitro_console_island island(',
         'nds_nitro_console_island island('+connections))
    def wrap(s):
        s = inject_vhdl_port(s)
        s = instance(s, 'inds', '''cp_area_in => cp_area_in, cp_area_out => cp_area_out,
      checkpoint_request => cp_area_in(48), checkpoint_keepalive => cp_area_in(49),
      checkpoint_keepalive_epoch => unsigned(cp_area_in(81 downto 50)),
      checkpoint_external_seen => cp_area_in(82), checkpoint_external_paused => cp_area_in(83),
      checkpoint_math_idle_2x => cp_area_in(88), checkpoint_read_strobe => cp_area_in(87),
      checkpoint_read_cpu => cp_area_in(0), checkpoint_read_address => cp_area_in(12 downto 5),
      checkpoint_read_epoch => unsigned(cp_area_in(81 downto 50))''',
          'CHECKPOINT_CPU_ENABLE => true, CHECKPOINT_OWNERS_ENABLE => true')
        # Raw restore must also be able to hold the real console reset. The
        # production boot FSM remains present; this is not a restore boot path.
        s = once(s, 'reset            => reset,', 'reset            => reset or cp_area_in(46),')
        return s
    edit(root, 'rtl/nds_nitro_console_wrap.vhd', wrap)
    edit(root, 'rtl/nds_nitro_console_top.vhd', instrument_console)
    def island(s):
        s = once(s, ') console (', ') console (.cp_area_in(cp_area_in), .cp_area_out(cp_area_console),')
        decl = '''
wire [127:0] cp_area_console;
wire [31:0] cp_area_math_data, cp_area_cdc_data;
wire cp_area_math_valid, cp_area_math_ready, cp_area_math_error;
wire cp_area_cdc_valid, cp_area_cdc_ready, cp_area_cdc_error;
wire cp_area_cdc_seen, cp_area_cdc_stopped, cp_area_ddr_request;
wire cp_area_math_selected = cp_area_in[4:0] == 5'd20;
wire cp_area_cdc_selected = cp_area_in[4:0] == 5'd21;
assign cp_area_out = cp_area_math_selected ?
    {92'd0,checkpoint_math_idle_2x,cp_area_math_error,cp_area_math_ready,cp_area_math_valid,cp_area_math_data} :
    cp_area_cdc_selected ?
    {90'd0,cp_area_ddr_request,cp_area_cdc_stopped,cp_area_cdc_seen,cp_area_cdc_error,cp_area_cdc_ready,cp_area_cdc_valid,cp_area_cdc_data} : cp_area_console;
'''
        s = once(s, 'nds_nitro_arm9_math_unit #(.COMBINATIONAL_READ', decl +
            "nds_nitro_arm9_math_unit #(.EXPERIMENTAL_CHECKPOINT(1'b1), .COMBINATIONAL_READ")
        s = once(s, '.clk(clk2x),.reset(console_reset_2x),',
                 '.clk(clk2x),.reset(console_reset_2x || cp_area_in[46]),')
        s = once(s, "nds_h3d_frame_record_cdc #(\n", "nds_h3d_frame_record_cdc #(\n    .EXPERIMENTAL_CHECKPOINT(1'b1),\n")
        s = once(s, ') h3d_record_cdc (\n    .source_clk(clk1x), .ddr_clk(ddr_clk),\n    .reset(bridge_reset_ddr), .session_flush(~h3d_control_release),',
                 ') h3d_record_cdc (\n    .source_clk(clk1x), .ddr_clk(ddr_clk),\n    .reset(bridge_reset_ddr || cp_area_in[46]), .session_flush(!cp_area_in[46] && !h3d_control_release),')
        old = '''.checkpoint_address(4'd0),.checkpoint_data(),.checkpoint_valid(),
    .checkpoint_restore(1'b0),.checkpoint_write(1'b0),.checkpoint_write_data(32'd0),
    .checkpoint_restore_ready(),.checkpoint_restore_error()'''
        new = '''.checkpoint_address(cp_area_in[8:5]),.checkpoint_data(cp_area_math_data),.checkpoint_valid(cp_area_math_valid),
    .checkpoint_restore(cp_area_in[46]),.checkpoint_write(cp_area_in[47] && cp_area_math_selected),.checkpoint_write_data(cp_area_in[45:14]),
    .checkpoint_restore_ready(cp_area_math_ready),.checkpoint_restore_error(cp_area_math_error)'''
        s = once(s, old, new)
        old = '''.checkpoint_request(1'b0), .checkpoint_producers_stopped(1'b0),
    .checkpoint_address(9'd0), .checkpoint_restore(1'b0),
    .checkpoint_write(1'b0), .checkpoint_write_data(32'd0),
    .checkpoint_ddr_ack(1'b0), .checkpoint_ddr_request(),
    .checkpoint_seen(), .checkpoint_stopped(), .checkpoint_data(),
    .checkpoint_valid(), .checkpoint_restore_ready(), .checkpoint_restore_error()'''
        new = '''.checkpoint_request(cp_area_in[48] || cp_area_in[46]), .checkpoint_producers_stopped(cp_area_in[85] || cp_area_in[46]),
    .checkpoint_address(cp_area_in[13:5]), .checkpoint_restore(cp_area_in[46]),
    .checkpoint_write(cp_area_in[47] && cp_area_cdc_selected), .checkpoint_write_data(cp_area_in[45:14]),
    .checkpoint_ddr_ack(cp_area_in[86]), .checkpoint_ddr_request(cp_area_ddr_request),
    .checkpoint_seen(cp_area_cdc_seen), .checkpoint_stopped(cp_area_cdc_stopped), .checkpoint_data(cp_area_cdc_data),
    .checkpoint_valid(cp_area_cdc_valid), .checkpoint_restore_ready(cp_area_cdc_ready), .checkpoint_restore_error(cp_area_cdc_error)'''
        return once(s, old, new)
    edit(root, 'rtl/nds_nitro_console_island.sv', island)
    qsf = root / PROJECT / 'NDS4MiSTer.qsf'
    with qsf.open('a') as f:
        f.write('\n# Area-only raw probe ports; NEVER assemble or deploy this project.\n')
        f.write('set_instance_assignment -name VIRTUAL_PIN ON -to "cp_area_in[*]"\n')
        f.write('set_instance_assignment -name VIRTUAL_PIN ON -to "cp_area_out[*]"\n')


def instrument_arm7_monitor(root):
    """Replace only ARM7 in the generated area copy; never a deployable core.

    Keep every actual guest bus/debug/export connection. Raw controls separately
    expose reset-held snapshot loading, maintenance execution and final release.
    The old read coordinator remains costed, but its image protocol is NOT the
    new 45-word format and this substitution is not functional integration.
    """
    def console(s):
        s = once(s, '   signal cp_area_sound_write_ready : std_logic;', '''   signal cp_area_sound_write_ready : std_logic;
   signal cp_mon_active, cp_mon_paused : std_logic;
   signal cp_mon_address : unsigned(5 downto 0);''')
        s = once(s, '   cp_area_ready(1 downto 0) <= "00"; cp_area_error(1 downto 0) <= "00";', '''   cp_area_ready(0) <= '0'; cp_area_error(0) <= '0';
   checkpoint_valid7 <= cp_mon_paused;
   cp_mon_address <= unsigned(checkpoint_addr7(5 downto 0)) when cp_area_in(89) = '0' else unsigned(cp_area_in(10 downto 5));''')
        s = once(s, '      cp_area_out(35) <= cp_area_sound_write_ready;', '''      cp_area_out(111) <= cp_mon_active;
      cp_area_out(112) <= cp_mon_paused;
      cp_area_out(35) <= cp_area_sound_write_ready;''')
        a = s.index('   icpu7 : entity work.gba_cpu')
        b = s.index('\n   ibios7 :', a)
        old = s[a:b]
        # Check the actual guest interface before replacing it in the copy.
        for name in ('cpu7_adr','cpu7_rnw','cpu7_ena','cpu7_acc','cpu7_dout','cpu7_din',
                     'cpu7_done','cpu7_lock','cpu7_lowbits','cpu7_pause','cpu7_bus_idle',
                     'cpu7_lastread','cpu7_irq','cpu7_unhalt','cpu7_newhalt','error_cpu7',
                     'pc7_s','dbg_regval7','dbg_export7_done','dbg_export7'):
            if name not in old:
                raise ValueError('ARM7 guest interface changed: '+name)
        replacement = '''   -- Generated synthesis probe, NOT a functional console restore path.
   icpu7 : entity work.nds_arm7_monitor_probe
   generic map(ENABLED => true, is_simu => is_simu)
   port map(clk => clk1x, ce => '1', reset => resetCpu and not cp_area_in(91),
      preset => cpu_save7, addr => cpu7_adr, rnw => cpu7_rnw, ena => cpu7_ena,
      seq => open, code => open, acc => cpu7_acc, dout => cpu7_dout,
      din => cpu7_din, bus_done => cpu7_done, lock => cpu7_lock, lowbits => cpu7_lowbits,
      dma => cpu7_pause, idle => cpu7_bus_idle, halted => open, lastread => cpu7_lastread,
      irq => cpu7_irq, unhalt => cpu7_unhalt or dbg_rel7 or diagnostic_release7,
      new_halt => cpu7_newhalt or dbg_hold7 or diagnostic_hold7,
      cpu_error => error_cpu7, dbg_pc => pc7_s, dbg_regsel => dbg_regsel_s, dbg_regval => dbg_regval7,
      -- synthesis translate_off
      cpu_export_done => dbg_export7_done, cpu_export => dbg_export7,
      -- synthesis translate_on
      request => checkpoint_req7, paused => cp_mon_paused, active => cp_mon_active,
      continue_run => cp_area_in(90), restore => cp_area_restore(1),
      release_run => cp_area_in(92), ready => cp_area_ready(1), error => cp_area_error(1),
      host_addr => cp_mon_address, host_write => cp_area_write(1),
      host_din => cp_area_in(45 downto 14), host_dout => checkpoint_data7);
   checkpoint_paused7 <= cp_mon_paused;
'''
        return s[:a]+replacement+s[b:]
    edit(root, 'rtl/nds_nitro_console_top.vhd', console)
    edit(root, PROJECT/'files.qip', lambda s: once(s,
        'set_global_assignment -name VHDL_FILE $nitro_rtl/gba_cpu.vhd',
        'set_global_assignment -name VHDL_FILE $nitro_rtl/gba_cpu.vhd\n'
        'set_global_assignment -name VHDL_FILE ../../rtl/nds_arm7_monitor_rom.vhd\n'
        'set_global_assignment -name VHDL_FILE ../../rtl/nds_arm7_monitor_probe.vhd'))


def prepare(repo, output, arm7_monitor=False):
    output.mkdir(parents=True, exist_ok=False)
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=repo).decode().split('\0')
    files = [n for n in files if n and (repo/n).is_file()]
    # Include this tool while it is still an untracked, reviewable development edit.
    tool = str(Path(__file__).resolve().relative_to(repo))
    files = sorted(set(files + [tool]))
    source = {name: digest(repo/name) for name in files}
    overrides = json.loads((repo/'docs/release/BETA12_BUILD_PROVENANCE.json').read_text())['fpga_qsf_override']['appended_text']
    for variant in ('baseline', 'connected'):
        root = output / variant
        root.mkdir()
        for name in files:
            target = root/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo/name, target)
        qsf = root / PROJECT / 'NDS4MiSTer.qsf'
        with qsf.open('a') as f:
            f.write(overrides)
        if variant == 'connected':
            instrument(root)
            if arm7_monitor:
                instrument_arm7_monitor(root)
        manifest = {name: digest(root/name) for name in files}
        (output/(variant.upper()+'_SOURCE.json')).write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
    receipt = {
        'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'source_commit': subprocess.check_output(['git','rev-parse','HEAD'], cwd=repo).decode().strip(),
        'source_status': subprocess.check_output(['git','status','--porcelain'], cwd=repo).decode(),
        'source': source, 'fpga_flags': overrides,
        'scope': 'Full shell synthesis with existing component capture/restore and acquisition connected to raw observable virtual pins. Not a usable transport, complete machine state, fit, timing or gameplay proof.',
        'unimplemented': ['RAM/cache/TCM serialization', 'downstream writer/renderer ownership', 'safe host transport/CDC', 'complete restore boot path'],
        'components': {'0':'ARM9', '1':'ARM7', **{str(n):label for n,label,_ in COMPONENTS}, '20':'math', '21':'CDC with packet frontend'},
        'arm7_monitor': arm7_monitor,
    }
    (output/'INPUTS.json').write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n')


def synthesis_counts(report):
    fields = {
        'estimated_alms': 'Estimate of Logic utilization (ALMs needed)',
        'combinational_aluts': 'Combinational ALUT usage for logic',
        'registers': 'Dedicated logic registers',
        'block_memory_bits': 'Total block memory bits',
        'dsp_blocks': 'Total DSP Blocks',
    }
    result = {}
    for key, title in fields.items():
        m = re.search(r';\s*'+re.escape(title)+r'\s*;\s*([\d,]+)\s*;', report)
        if m:
            result[key] = int(m[1].replace(',',''))
    return result


def validate_probe_pins(root, variant):
    report = (root/PROJECT/'output_files/NDS4MiSTer.map.rpt').read_text()
    if 'Ignored assignment VIRTUAL_PIN' in report:
        raise RuntimeError('Probe virtual-pin assignments were rejected: '+variant)
    if variant == 'connected':
        summary = (root/PROJECT/'output_files/NDS4MiSTer.map.summary').read_text()
        if not re.search(r'Total virtual pins\s*:\s*224\b', summary):
            raise RuntimeError('Expected all 224 probe pins to be virtual')


def summarize(output, baseline_output=None):
    result = {'scope':'Matched full-shell synthesis, not whole-machine fit or gameplay qualification.'}
    result['arm7_monitor'] = json.loads((output/'INPUTS.json').read_text()).get('arm7_monitor',False)
    if baseline_output:
        old = json.loads((baseline_output/'INPUTS.json').read_text())
        new = json.loads((output/'INPUTS.json').read_text())
        # Reuse completed mapping only when every non-doc/tool input is equal.
        # Generated instrumentation is separately frozen in each manifest.
        hardware = lambda d: {k:v for k,v in d['source'].items() if not k.startswith(('docs/','tools/'))}
        if hardware(old) != hardware(new) or old['fpga_flags'] != new['fpga_flags']:
            raise RuntimeError('Reused baseline has different hardware inputs')
        result['reused_baseline_output'] = str(baseline_output)
    entities = {}
    for variant in ('baseline','connected'):
        evidence = baseline_output if variant == 'baseline' and baseline_output else output
        receipt = json.loads((evidence/(variant.upper()+'_RESULT.json')).read_text())
        if receipt['exit_code'] != 0:
            raise RuntimeError('Cannot compare failed mapping: '+variant)
        root = evidence/variant
        manifest = json.loads((evidence/(variant.upper()+'_SOURCE.json')).read_text())
        if not all(digest(root/name)==expected for name,expected in manifest.items()):
            raise RuntimeError('Frozen source changed: '+variant)
        report = root/PROJECT/'output_files/NDS4MiSTer.map.rpt'
        body = report.read_text()
        validate_probe_pins(root,variant)
        result[variant] = synthesis_counts(body)
        result[variant+'_report_sha256'] = digest(report)
        for line in body.splitlines():
            cols = [c.strip() for c in line.split(';')]
            if len(cols) != 12 or not re.fullmatch(r'\d+ \(\d+\)',cols[2]):
                continue
            key = cols[8]
            entities.setdefault(key,{})[variant] = {
                'entity':cols[9], 'aluts_total':int(cols[2].split()[0]),
                'aluts_local':int(cols[2].split('(')[1].rstrip(')')),
                'registers_total':int(cols[3].split()[0]),
                'registers_local':int(cols[3].split('(')[1].rstrip(')')),
            }
    result['delta'] = {k:result['connected'][k]-v for k,v in result['baseline'].items()}
    result['frozen_sources_unchanged'] = True
    result['testable_gameplay_beta'] = False
    result['full_fit_or_timing_proved'] = False
    (output/'COUNTS.json').write_text(json.dumps(result,indent=2)+'\n')
    (output/'ENTITIES.json').write_text(json.dumps(entities,sort_keys=True,indent=2)+'\n')
    print(json.dumps(result,indent=2))


def run_stage(output, variant, stage, runtime, shim):
    root = output/variant
    manifest = json.loads((output/(variant.upper()+'_SOURCE.json')).read_text())
    for name, expected in manifest.items():
        if digest(root/name) != expected:
            raise RuntimeError('Frozen source changed: '+name)
    if stage == 'fit':
        mapped = json.loads((output/(variant.upper()+'_RESULT.json')).read_text())
        if mapped['exit_code'] != 0:
            raise RuntimeError('A successful map is required before fitting')
        validate_probe_pins(root,variant)
    log_path = output/(variant+'-'+stage+'.log')
    if log_path.exists():
        raise RuntimeError('Refusing to replace an existing build log')
    cmd = ['docker','run','--rm','--network','none','--platform','linux/amd64',
           '--name','nds-cp-area-'+variant,
           '-v',str(root)+':/workspace','-v',str(runtime)+':/quartus-runtime:ro',
           '-v',str(shim)+':/usr/lib/x86_64-linux-gnu/libudev.so.1:ro',
           '-e','LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libudev.so.1',
           '-w','/workspace/'+str(PROJECT),
           '--entrypoint','/quartus-runtime/quartus/bin/quartus_'+stage,
           'nds4mister-quartus-runtime:17.0.2','NDS4MiSTer','--write_settings_files=off']
    with log_path.open('w') as log:
        code = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
    summary_path = root/PROJECT/('output_files/NDS4MiSTer.'+stage+'.summary')
    report_path = summary_path.with_suffix('.rpt')
    result = {'exit_code':code, 'log':str(log_path), 'summary':str(summary_path),
              'completed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'driver_sha256':digest(Path(__file__)), 'stage':stage,
              'full_fit_or_timing_proved':False, 'testable_gameplay_beta':False}
    if summary_path.is_file():
        result['summary_text'] = summary_path.read_text()
    if report_path.is_file():
        result['report_sha256'] = digest(report_path)
        if stage == 'map' and code == 0:
            result['synthesis_counts'] = synthesis_counts(report_path.read_text())
    result['frozen_sources_unchanged'] = all(digest(root/name)==expected for name,expected in manifest.items())
    suffix = '_FIT_RESULT.json' if stage == 'fit' else '_RESULT.json'
    (output/(variant.upper()+suffix)).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2), flush=True)
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--arm7-monitor', action='store_true',
                        help='During prepare, substitute complete ARM7 monitor in the generated connected area probe only')
    parser.add_argument('--summarize', action='store_true')
    parser.add_argument('--baseline-output', type=Path,
                        help='Reuse a completed baseline after verifying identical hardware inputs')
    parser.add_argument('--variant', choices=['baseline','connected'])
    parser.add_argument('--stage', choices=['map','fit'], default='map',
                        help='Fit is optional, requires a successful map, and never assembles an image')
    parser.add_argument('--runtime', type=Path)
    parser.add_argument('--udev-shim', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output == repo or repo in output.parents:
        parser.error('Generated projects must be outside the source checkout')
    if args.prepare:
        prepare(repo, output, args.arm7_monitor)
    if args.summarize:
        summarize(output, args.baseline_output.resolve() if args.baseline_output else None)
    if args.variant:
        if not args.runtime or not args.udev_shim:
            parser.error('Mapping needs --runtime and --udev-shim')
        raise SystemExit(run_stage(output,args.variant,args.stage,args.runtime.resolve(),args.udev_shim.resolve()))
    if not (args.prepare or args.summarize):
        parser.error('Choose --prepare, --variant or --summarize')


if __name__ == '__main__':
    main()
