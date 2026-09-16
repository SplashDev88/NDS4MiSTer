// SPDX-License-Identifier: GPL-2.0
/*
 * Restricted write-combined mapping for NDS4MiSTer's HPS-published pixels.
 *
 * DreamSTer demonstrated that Normal Non-Cacheable/write-combined mappings
 * avoid the per-word AXI serialization imposed by ARM /dev/mem Device memory.
 * Unlike a general write-combined /dev/mem replacement, this node accepts
 * mmap() only inside NDS4MiSTer's fixed three-megabyte publication window.
 * The control header and packet rings are deliberately excluded so their
 * Device-memory ordering semantics cannot change.
 */

#include <linux/fs.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>

#define NDS_MEM_WC_NAME "nds_mem_wc"
#define NDS_PUBLICATION_PHYS_BASE 0x3fd00000UL
#define NDS_PUBLICATION_PHYS_SIZE 0x00300000UL

static int nds_mem_wc_mmap(struct file *file, struct vm_area_struct *vma)
{
	const size_t size = vma->vm_end - vma->vm_start;
	const phys_addr_t offset = (phys_addr_t)vma->vm_pgoff << PAGE_SHIFT;
	const phys_addr_t limit =
		(phys_addr_t)NDS_PUBLICATION_PHYS_BASE +
		NDS_PUBLICATION_PHYS_SIZE;

	if (!size || offset + size < offset ||
	    offset < NDS_PUBLICATION_PHYS_BASE || offset + size > limit)
		return -EPERM;

	vma->vm_flags |= VM_IO | VM_DONTEXPAND | VM_DONTDUMP;
	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
	if (remap_pfn_range(vma, vma->vm_start, vma->vm_pgoff,
			    size, vma->vm_page_prot))
		return -EAGAIN;

	return 0;
}

static const struct file_operations nds_mem_wc_fops = {
	.owner = THIS_MODULE,
	.mmap = nds_mem_wc_mmap,
	.llseek = noop_llseek,
};

static struct miscdevice nds_mem_wc_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = NDS_MEM_WC_NAME,
	.fops = &nds_mem_wc_fops,
	.mode = 0600,
};

static int __init nds_mem_wc_init(void)
{
	int result = misc_register(&nds_mem_wc_device);

	if (result)
		return result;
	pr_info("nds_mem_wc: restricted window [0x%lx, 0x%lx)\n",
		NDS_PUBLICATION_PHYS_BASE,
		NDS_PUBLICATION_PHYS_BASE + NDS_PUBLICATION_PHYS_SIZE);
	return 0;
}

static void __exit nds_mem_wc_exit(void)
{
	misc_deregister(&nds_mem_wc_device);
}

module_init(nds_mem_wc_init);
module_exit(nds_mem_wc_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("NDS4MiSTer contributors");
MODULE_DESCRIPTION("Restricted write-combined NDS4MiSTer publication window");
