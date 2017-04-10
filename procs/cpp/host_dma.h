#pragma once

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mutex>
#include <condition_variable>
#include <sys/types.h>
#include "GeneratedTypes.h"
#include "HostDmaIndication.h"
#include "HostDmaRequest.h"
#include "fesvr/packet.h"

class HostDmaIndication : public HostDmaIndicationWrapper {
private:
    // # of bytes in one burst to FPGA
    static const int data_bytes = sizeof(uint64_t);
    // max burst to FPGA in 1 DMA req (due to AXI)
    static const int max_burst_num = 256;

    const bool verbose;

    // req proxy to FPGA
    HostDmaRequestProxy *reqProxy;

    // only 1 DMA req in flight, use lock to protect
    // FIXME this lock may not be necessary since dma_read/write is only called by riscy_htif
    // and we have locks on riscy_htif
    std::mutex dma_mu;

    // mutex & cond var to coordinate the processing of FPGA resp
    std::mutex process_mu;
    std::condition_variable process_cv;

    // dma read params
    bool read_pending; // set by dma_read, reset when all FPGA resp got
    char *read_dst; // destination data buffer (incr after each FPGA resp)
    int read_total_burst_num; // total # of bursts for dma read
    int read_resp_cnt; // incr from 0 at every rdData indication
    int first_read_skip_bytes; // # of LSBs to skip in the first resp
    int last_read_drop_bytes; // # of MSBs to drop in the last resp

    // dma write params
    bool write_pending; // set by dma_write, reset by wrDone

    uint8_t inline get_write_be(int skip_lsb, int write_bytes) {
        uint8_t be = (uint8_t)(-1);
        be = be >> (data_bytes - write_bytes);
        be = be << skip_lsb;
        return be;
    }

public:
    HostDmaIndication(int id);
    virtual ~HostDmaIndication();

    virtual void rdData (const uint64_t data, const uint8_t id);
    virtual void wrDone ();

    virtual void dramErr (const uint8_t err) {
        fprintf(stderr, "[ERROR] DRAM error code %d\n", (int)err);
        exit(1);
    }
    virtual void dramStatus (const int init) {
        fprintf(stderr, "[INFO] DRAM init = %d\n", init);
    }

    void set_req_proxy(HostDmaRequestProxy *p) {
        reqProxy = p;
        reqProxy->pint.busyType = BUSY_SPIN;
    }

    void dma_read(addr_t addr, size_t len, void *dst);
    void dma_write(addr_t addr, size_t len, const void *src);
};
