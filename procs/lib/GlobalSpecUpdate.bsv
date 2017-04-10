import ProcTypes::*;
import HasSpecBits::*;
import GetPut::*;
import Vector::*;
import ReorderBuffer::*;

interface GlobalSpecUpdate#(numeric type correctSpecPortNum, numeric type conflictWrongSpecPortNum);
    interface Vector#(correctSpecPortNum, Put#(SpecTag)) correctSpec;
    method Action incorrectSpec(SpecTag spec_tag, InstTag inst_tag);
    // Some rules (e.g. doFinishFpuMulDiv) in Core.bsv may not conflict with wrong spec
    // and is ordered before rules that calls incorrectSpec
    // this creates cycles in scheduling
    // To break the cycle, such rules can call the following interface
    // to manually create a conflict with rules that do incorrectSpec
    interface Vector#(conflictWrongSpecPortNum, Put#(void)) conflictWrongSpec;
endinterface

module mkGlobalSpecUpdate#(
    SpeculationUpdate ifc, ROB_SpeculationUpdate rob
    // ROB is treatly separatly due to an optimization on killing
)(
    GlobalSpecUpdate#(correctSpecPortNum, conflictWrongSpecPortNum)
);
    // record correct spec tags
    Vector#(correctSpecPortNum, RWire#(SpecTag)) correctSpecTag <- replicateM(mkRWire);
    // make wrong spec conflict with correct spec
    Vector#(correctSpecPortNum, RWire#(void)) spec_conflict <- replicateM(mkRWire);
    // let the caller of conflictWrongSpec to be conflict with wrong spec
    Vector#(conflictWrongSpecPortNum, RWire#(void)) wrongSpec_conflict <- replicateM(mkRWire);

    (* fire_when_enabled, no_implicit_conditions *)
    rule canon_correct_spec;
        SpecBits mask = maxBound;
        for(Integer i = 0; i < valueof(correctSpecPortNum); i = i+1) begin
            if(correctSpecTag[i].wget matches tagged Valid .tag) begin
                mask[tag] = 0;
            end
        end
        ifc.correctSpeculation(mask);
        rob.correctSpeculation(mask);
    endrule

    Vector#(correctSpecPortNum, Put#(SpecTag)) correctVec = ?;
    for(Integer i = 0; i < valueof(correctSpecPortNum); i = i+1) begin
        correctVec[i] = (interface Put;
            method Action put(SpecTag t);
                correctSpecTag[i].wset(t);
                // conflict with wrong spec
                spec_conflict[i].wset(?);
            endmethod
        endinterface);
    end

    Vector#(conflictWrongSpecPortNum, Put#(void)) conflictWrongVec = ?;
    for(Integer i = 0; i < valueof(conflictWrongSpecPortNum); i = i+1) begin
        conflictWrongVec[i] = (interface Put;
            method Action put(void x);
                wrongSpec_conflict[i].wset(?);
            endmethod
        endinterface);
    end

    interface correctSpec = correctVec;

    method Action incorrectSpec(SpecTag spec_tag, InstTag inst_tag);
        ifc.incorrectSpeculation(spec_tag);
        rob.incorrectSpeculation(spec_tag, inst_tag);
        // conflict with correct spec
        for(Integer i = 0; i < valueof(correctSpecPortNum); i = i+1) begin
            spec_conflict[i].wset(?);
        end
        // conflict with the caller of conflictWrongSpec
        for(Integer i = 0; i < valueof(conflictWrongSpecPortNum); i = i+1) begin
            wrongSpec_conflict[i].wset(?);
        end
    endmethod

    interface conflictWrongSpec = conflictWrongVec;
endmodule
