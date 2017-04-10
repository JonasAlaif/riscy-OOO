import Types::*;
import ProcTypes::*;
import RegFile::*;
import Ehr::*;
import Vector::*;
import GlobalBrHistReg::*;
import BrPred::*;

export TourLocalHistSz;
export TourLocalHist;
export TourGlobalHistSz;
export TourGlobalHist;
export TourTrainInfo(..);
export mkTourPred;

// 4KB tournament predictor

typedef 12 TourGlobalHistSz;
typedef 10 TourLocalHistSz;
typedef 10 PCIndexSz;

typedef Bit#(TourGlobalHistSz) TourGlobalHist;
typedef Bit#(TourLocalHistSz) TourLocalHist;
typedef Bit#(PCIndexSz) PCIndex;

typedef struct {
    TourGlobalHist globalHist;
    TourLocalHist localHist;
    Bool globalTaken;
    Bool localTaken;
} TourTrainInfo deriving(Bits, Eq, FShow);

// global history reg
typedef GlobalBrHistReg#(TourGlobalHistSz) TourGHistReg;

(* synthesize *)
module mkTourGHistReg(TourGHistReg);
    let m <- mkGlobalBrHistReg;
    return m;
endmodule

(* synthesize *)
module mkTourPred(DirPredictor#(TourTrainInfo));
    // local history: MSB is the latest branch
    RegFile#(PCIndex, TourLocalHist) localHistTab <- mkRegFileWCF(0, maxBound);
    // local sat counters
    RegFile#(TourLocalHist, Bit#(3)) localBht <- mkRegFileWCF(0, maxBound);
    // global history reg
    TourGHistReg gHistReg <- mkTourGHistReg;
    // global sat counters
    RegFile#(TourGlobalHist, Bit#(2)) globalBht <- mkRegFileWCF(0, maxBound);
    // choice sat counters: large (taken) -- use local, small (not taken) -- use global
    RegFile#(TourGlobalHist, Bit#(2)) choiceBht <- mkRegFileWCF(0, maxBound);

    // EHR to record predict results in this cycle
    Ehr#(TAdd#(1, SupSize), SupCnt) predCnt <- mkEhr(0);
    Ehr#(TAdd#(1, SupSize), Bit#(SupSize)) predRes <- mkEhr(0);

    function PCIndex getPCIndex(Addr pc);
        return truncate(pc >> 2);
    endfunction

    // common sat counter operations
    function Bool isTaken(Bit#(n) cnt) provisos(Add#(1, a__, n));
        Bit#(1) msb = truncateLSB(cnt);
        return msb == 1;
    endfunction

    function Bit#(n) updateCnt(Bit#(n) cnt, Bool taken);
        if(taken) begin
            return cnt == maxBound ? maxBound : cnt + 1;
        end
        else begin
            return cnt == 0 ? 0 : cnt - 1;
        end
    endfunction

    TourGlobalHist curGHist = gHistReg.history; // global history: MSB is the latest branch

    Vector#(SupSize, DirPred#(TourTrainInfo)) predIfc;
    for(Integer i = 0; i < valueof(SupSize); i = i+1) begin
        predIfc[i] = (interface DirPred;
            method ActionValue#(DirPredResult#(TourTrainInfo)) pred(Addr pc);
                // get local history & prediction
                TourLocalHist localHist = localHistTab.sub(getPCIndex(pc));
                Bool localTaken = isTaken(localBht.sub(localHist));

                // get the global history
                // all previous branch in this cycle must be not taken
                // otherwise this branch should be on wrong path
                // because all inst in same cycle are fetched consecutively
                TourGlobalHist globalHist = curGHist >> predCnt[i];
                // get global prediction
                Bool globalTaken = isTaken(globalBht.sub(globalHist));

                // make choice
                Bool useLocal = isTaken(choiceBht.sub(globalHist));
                Bool taken = useLocal ? localTaken : globalTaken;

                // record prediction
                predCnt[i] <= predCnt[i] + 1;
                Bit#(SupSize) res = predRes[i];
                res[predCnt[i]] = pack(taken);
                predRes[i] <= res;

                // return
                return DirPredResult {
                    taken: taken,
                    train: TourTrainInfo {
                        globalHist: globalHist,
                        localHist: localHist,
                        globalTaken: globalTaken,
                        localTaken: localTaken
                    }
                };
            endmethod
        endinterface);
    end

    (* fire_when_enabled, no_implicit_conditions *)
    rule canonGlobalHist;
        gHistReg.addHistory(predRes[valueof(SupSize)], predCnt[valueof(SupSize)]);
        predRes[valueof(SupSize)] <= 0;
        predCnt[valueof(SupSize)] <= 0;
    endrule

    interface pred = predIfc;

    method Action update(Addr pc, Bool taken, TourTrainInfo train, Bool mispred);
        // update history if mispred
        if(mispred) begin
            TourGlobalHist newHist = truncateLSB({pack(taken), train.globalHist});
            gHistReg.redirect(newHist);
        end
        // update local history (assume only 1 branch for an PC in flight)
        localHistTab.upd(getPCIndex(pc), truncateLSB({pack(taken), train.localHist}));
        // update local sat cnt
        let localCnt = localBht.sub(train.localHist);
        localBht.upd(train.localHist, updateCnt(localCnt, taken));
        // update global sat cnt
        let globalCnt = globalBht.sub(train.globalHist);
        globalBht.upd(train.globalHist, updateCnt(globalCnt, taken));
        // update choice cnt
        if(train.globalTaken != train.localTaken) begin
            Bool useLocal = train.localTaken == taken;
            let choiceCnt = choiceBht.sub(train.globalHist);
            choiceBht.upd(train.globalHist, updateCnt(choiceCnt, useLocal));
        end
    endmethod
endmodule
