using LinearAlgebra
using Fermi.DIIS

"""
    Fermi.CoupledCluster.RCCSD{T}(Alg::CTF)

Compute a RCCSD wave function using the Compiled time factorization algorithm (CTF)
"""
function RCCSD{T}(guess::RCCSD{Tb},Alg::CTF) where { T <: AbstractFloat,
                                                    Tb <: AbstractFloat }
    molecule = Fermi.Geometry.Molecule()
    aoint = Fermi.Integrals.ConventionalAOIntegrals(molecule)
    refwfn = Fermi.HartreeFock.RHF(molecule, aoint)

    drop_occ = Fermi.CurrentOptions["drop_occ"]
    drop_vir = Fermi.CurrentOptions["drop_vir"]

    @output "Transforming Integrals..."
    tint = @elapsed moint = Fermi.Integrals.PhysRestrictedMOIntegrals{T}(refwfn.ndocc, refwfn.nvir, drop_occ, drop_vir, refwfn.C, aoint)
    @output " done in {} s" tint
    RCCSD{T}(refwfn, guess, moint, Alg) 
end

"""
    Fermi.CoupledCluster.RCCSD{T}(refwfn::RHF, moint::PhysRestrictedMOIntegrals, Alg::CTF)

Compute a RCCSD wave function using the Compiled time factorization algorithm (CTF). Precision (T), reference wavefunction (refwfn)
and molecular orbital integrals (moint) must be passed.
"""
function RCCSD{T}(refwfn::RHF, guess::RCCSD{Tb}, moint::PhysRestrictedMOIntegrals, Alg::CTF) where { T <: AbstractFloat,
                                                                                                    Tb <: AbstractFloat }
    d = [i - a for i = diag(moint.oo), a = diag(moint.vv)]
    D = [i + j - a - b for i = diag(moint.oo), j = diag(moint.oo), a = diag(moint.vv), b = diag(moint.vv)]
    newT1 = moint.ov./d
    newT2 = moint.oovv./D
    o_small,v_small = size(guess.T1)
    o = 1:o_small
    v = 1:v_small
    newT1[o,v] .= Fermi.data(guess.T1)
    newT2[o,o,v,v] .= Fermi.data(guess.T2)
    RCCSD{T}(refwfn, moint, newT1, newT2, Alg)
end

"""
    Fermi.CoupledCluster.RCCSD{T}(refwfn::RHF, moint::PhysRestrictedMOIntegrals, Alg::CTF)

Base function for CTF RCCSD.
"""
function RCCSD{T}(refwfn::RHF, moint::PhysRestrictedMOIntegrals, newT1::Array{T, 2}, newT2::Array{T,4}, Alg::CTF) where T <: AbstractFloat

    d = [i - a for i = diag(moint.oo), a = diag(moint.vv)]
    D = [i + j - a - b for i = diag(moint.oo), j = diag(moint.oo), a = diag(moint.vv), b = diag(moint.vv)]
    # Print intro
    Fermi.CoupledCluster.print_header()
    @output "\n    • Computing CCSD with the CFT algorithm .\n\n"

    # Process Fock matrix, important for non HF cases
    foo = similar(moint.oo)
    foo .= moint.oo - Diagonal(moint.oo)
    fvv = similar(moint.vv)
    fvv .= moint.vv - Diagonal(moint.vv)
    fov = moint.ov

    # Compute Guess Energy
    Ecc = update_energy(newT1, newT2, fov, moint.oovv)
    Eguess = Ecc+refwfn.energy
    
    @output "Initial Amplitudes Guess: MP2\n"
    @output "MP2 Energy:   {:15.10f}\n\n" Ecc
    @output "MP2 Total Energy:   {:15.10f}\n\n" Ecc+refwfn.energy
    
    # Start CC iterations
    
    cc_max_iter = Fermi.CurrentOptions["cc_max_iter"]
    cc_e_conv = Fermi.CurrentOptions["cc_e_conv"]
    cc_max_rms = Fermi.CurrentOptions["cc_max_rms"]
    preconv_T1 = Fermi.CurrentOptions["preconv_T1"]
    dp = Fermi.CurrentOptions["cc_damp_ratio"]
    do_diis = Fermi.CurrentOptions["diis"]
    do_diis ? DM_T1 = Fermi.DIIS.DIISManager{Float64,Float64}(size=8) : nothing
    do_diis ? DM_T2 = Fermi.DIIS.DIISManager{Float64,Float64}(size=8) : nothing


    @output "    Starting CC Iterations\n\n"
    @output "Iteration Options:\n"
    @output "   cc_max_iter →  {:3.0d}\n" Int(cc_max_iter)
    @output "   cc_e_conv   →  {:2.0e}\n" cc_e_conv
    @output "   cc_max_rms  →  {:2.0e}\n\n" cc_max_rms

    r1 = 1
    r2 = 1
    dE = 1
    rms = 1
    ite = 1
    T1 = deepcopy(newT1)
    T2 = deepcopy(newT2)


    preconv_T1 ? T1_time = 0 : nothing
    if preconv_T1
        @output "Preconverging T1 amplitudes\n"
        @output "Taking one T2 step\n"
        @output "{:10s}    {: 15s}    {: 12s}    {:12s}    {:10s}\n" "Iteration" "CC Energy" "ΔE" "Max RMS (T1)" "Time (s)"
        t = @elapsed begin 
            update_amp(T1, T2, newT1, newT2, foo, fov, fvv, moint)

            # Apply resolvent
            newT1 ./= d
            newT2 ./= D

            # Compute residues 
            r1 = sqrt(sum((newT1 .- T1).^2))/length(T1)
            r2 = sqrt(sum((newT2 .- T2).^2))/length(T2)

            if do_diis 
                e1 = (newT1 - T1)
                e2 = (newT2 - T2)
                push!(DM_T1,newT1,e1) 
                push!(DM_T2,newT2,e2) 
                #newT1 = Fermi.DIIS.extrapolate(DM_T1)
                #newT2 = Fermi.DIIS.extrapolate(DM_T2)
            end

            newT1 .= (1-dp)*newT1 .+ dp*T1
            newT2 .= (1-dp)*newT2 .+ dp*T2
        end
        T1_time += t

        rms = max(r1,r2)
        oldE = Ecc
        Ecc = update_energy(newT1, newT2, fov, moint.oovv)
        dE = Ecc - oldE
        @output "    {:<5}    {:<15.10f}    {:<12.10f}    {:<12.10f}    {:<10.5f}\n" "pre" Ecc dE rms t

        while abs(dE) > cc_e_conv || rms > cc_max_rms
            if ite > cc_max_iter
                @output "\n⚠️  CC Equations did not converge in {:1.0d} iterations.\n" cc_max_iter
                break
            end
            t = @elapsed begin
                T1 .= newT1
                T2 .= newT2
                update_T1(T1,T2,newT1,foo,fov,fvv,moint)
                newT1 ./= d
                if do_diis 
                    e1 = newT1 - T1
                    push!(DM_T1,newT1,e1) 
                    newT1 = Fermi.DIIS.extrapolate(DM_T1)
                end

                # Compute residues 
                r1 = sqrt(sum((newT1 .- T1).^2))/length(T1)

                newT1 .= (1-dp)*newT1 .+ dp*T1

                rms = r1
                oldE = Ecc
                Ecc = update_energy(newT1, newT2, fov, moint.oovv)
                dE = Ecc - oldE
            end
            T1_time += t
            @output "    {:<5.0d}    {:<15.10f}    {:<12.10f}    {:<12.10f}    {:<10.5f}\n" ite Ecc dE rms t
            ite += 1
        end
        @output "\nT1 pre-convergence took {}s\n" T1_time
    end

    dE = 1
    rms = 1
    ite = 1

    do_diis ? DM_T1 = Fermi.DIIS.DIISManager{Float64,Float64}(size=6) : nothing
    do_diis ? DM_T2 = Fermi.DIIS.DIISManager{Float64,Float64}(size=6) : nothing
    if preconv_T1
        @output "Including T2 update\n"
    end

    main_time = 0
    @output "{:10s}    {: 15s}    {: 12s}    {:12s}    {:10s}\n" "Iteration" "CC Energy" "ΔE" "Max RMS" "Time (s)"

    while (abs(dE) > cc_e_conv || rms > cc_max_rms) 
        if ite > cc_max_iter
            @output "\n⚠️  CC Equations did not converge in {:1.0d} iterations.\n" cc_max_iter
            break
        end
        t = @elapsed begin

            T1 .= newT1
            T2 .= newT2
            update_amp(T1, T2, newT1, newT2, foo, fov, fvv, moint)

            # Apply resolvent
            newT1 ./= d
            newT2 ./= D

            # Compute residues 
            r1 = sqrt(sum((newT1 .- T1).^2))/length(T1)
            r2 = sqrt(sum((newT2 .- T2).^2))/length(T2)

            if do_diis 
                e1 = (newT1 - T1)
                e2 = (newT2 - T2)
                push!(DM_T1,newT1,e1) 
                push!(DM_T2,newT2,e2) 
                if length(DM_T2) > DM_T2.max_vec
                    newT2 = Fermi.DIIS.extrapolate(DM_T2)
                    newT1 = Fermi.DIIS.extrapolate(DM_T1)
                end
            end



            newT1 .= (1-dp)*newT1 .+ dp*T1
            newT2 .= (1-dp)*newT2 .+ dp*T2
        end
        rms = max(r1,r2)
        oldE = Ecc
        Ecc = update_energy(newT1, newT2, fov, moint.oovv)
        dE = Ecc - oldE
        main_time += t
        @output "    {:<5.0d}    {:<15.10f}    {:<12.10f}    {:<12.10f}    {:<10.5f}\n" ite Ecc dE rms t
        ite += 1
    end
    @output "\nMain CCSD iterations done in {}s\n" main_time

    # Converged?
    if abs(dE) < cc_e_conv && rms < cc_max_rms 
        @output "\n 🍾 Equations Converged!\n"
    end
    @output "\n⇒ Final CCSD Energy:     {:15.10f}\n" Ecc+refwfn.energy

    return RCCSD{T}(Eguess, Ecc+refwfn.energy, Fermi.MemTensor(newT1), Fermi.MemTensor(newT2))
end

"""
    Fermi.Coupled Cluster.update_energy(T1::Array{T, 2}, T2::Array{T, 4}, f::Array{T,2}, Voovv::Array{T, 4}) where T <: AbstractFloat

Compute CC energy from amplitudes and integrals.
"""
function update_energy(T1::Array{T, 2}, T2::Array{T, 4}, f::Array{T,2}, Voovv::Array{T, 4}) where T <: AbstractFloat

    @tensoropt (k=>x, l=>x, c=>100x, d=>100x)  begin
        CC_energy = 2.0*f[k,c]*T1[k,c]
        B[l,c,k,d] := -1.0*T1[l,c]*T1[k,d]
        B[l,c,k,d] += -1.0*T2[l,k,c,d]
        B[l,c,k,d] += 2.0*T2[k,l,c,d]
        CC_energy += B[l,c,k,d]*Voovv[k,l,c,d]
        CC_energy += 2.0*T1[l,c]*T1[k,d]*Voovv[l,k,c,d]
    end
    
    return CC_energy
end

"""
    Fermi.CoupledCluster.RCCSD.update_amp(T1::Array{T, 2}, T2::Array{T, 4}, newT1::Array{T,2}, newT2::Array{T,4}, foo::Array{T,2}, fov::Array{T,2}, fvv::Array{T,2}, moint::PhysRestrictedMOIntegrals) where T <: AbstractFloat

Update amplitudes (T1, T2) to newT1 and newT2 using CTF CCSD equations.
"""
function update_amp(T1::Array{T, 2}, T2::Array{T, 4}, newT1::Array{T,2}, newT2::Array{T,4}, foo::Array{T,2}, fov::Array{T,2}, fvv::Array{T,2}, moint::PhysRestrictedMOIntegrals) where T <: AbstractFloat

    Voooo, Vooov, Voovv, Vovov, Vovvv, Vvvvv = moint.oooo, moint.ooov, moint.oovv, moint.ovov, moint.ovvv, moint.vvvv

    fill!(newT1, 0.0)
    fill!(newT2, 0.0)

    # Get new amplitudes
    update_T1(T1,T2,newT1,foo,fov,fvv,moint)
    update_T2(T1,T2,newT2,foo,fov,fvv,moint)
end

function update_T1(T1::Array{T,2}, T2::Array{T,4}, newT1::Array{T,2}, foo, fov, fvv, moint::PhysRestrictedMOIntegrals) where T <: AbstractFloat
    Voooo, Vooov, Voovv, Vovov, Vovvv, Vvvvv = moint.oooo, moint.ooov, moint.oovv, moint.ovov, moint.ovvv, moint.vvvv
    @tensoropt (i=>x, j=>x, k=>x, l=>x, a=>10x, b=>10x, c=>10x, d=>10x) begin
        newT1[i,a] += fov[i,a]
        newT1[i,a] -= foo[i,k]*T1[k,a]
        newT1[i,a] += fvv[c,a]*T1[i,c]
        newT1[i,a] -= fov[k,c]*T1[i,c]*T1[k,a]
        newT1[i,a] += 2.0*fov[k,c]*T2[i,k,a,c]
        newT1[i,a] -= fov[k,c]*T2[k,i,a,c]
        newT1[i,a] -= T1[k,c]*Vovov[i,c,k,a]
        newT1[i,a] += 2.0*T1[k,c]*Voovv[k,i,c,a]
        newT1[i,a] -= T2[k,i,c,d]*Vovvv[k,a,d,c]
        newT1[i,a] += 2.0*T2[i,k,c,d]*Vovvv[k,a,d,c]
        newT1[i,a] += -2.0*T2[k,l,a,c]*Vooov[k,l,i,c]
        newT1[i,a] += T2[l,k,a,c]*Vooov[k,l,i,c]
        newT1[i,a] += -2.0*T1[k,c]*T1[l,a]*Vooov[l,k,i,c]
        newT1[i,a] -= T1[k,c]*T1[i,d]*Vovvv[k,a,d,c]
        newT1[i,a] += 2.0*T1[k,c]*T1[i,d]*Vovvv[k,a,c,d]
        newT1[i,a] += T1[k,c]*T1[l,a]*Vooov[k,l,i,c]
        newT1[i,a] += -2.0*T1[k,c]*T2[i,l,a,d]*Voovv[l,k,c,d]
        newT1[i,a] += -2.0*T1[k,c]*T2[l,i,a,d]*Voovv[k,l,c,d]
        newT1[i,a] += T1[k,c]*T2[l,i,a,d]*Voovv[l,k,c,d]
        newT1[i,a] += -2.0*T1[i,c]*T2[l,k,a,d]*Voovv[l,k,c,d]
        newT1[i,a] += T1[i,c]*T2[l,k,a,d]*Voovv[k,l,c,d]
        newT1[i,a] += -2.0*T1[l,a]*T2[i,k,d,c]*Voovv[k,l,c,d]
        newT1[i,a] += T1[l,a]*T2[i,k,c,d]*Voovv[k,l,c,d]
        newT1[i,a] += T1[k,c]*T1[i,d]*T1[l,a]*Voovv[l,k,c,d]
        newT1[i,a] += -2.0*T1[k,c]*T1[i,d]*T1[l,a]*Voovv[k,l,c,d]
        newT1[i,a] += 4.0*T1[k,c]*T2[i,l,a,d]*Voovv[k,l,c,d]
    end
end

function update_T2(T1::Array{T,2},T2::Array{T,4},newT2::Array{T,4},foo,fov,fvv,moint::PhysRestrictedMOIntegrals) where T <: AbstractFloat
    Voooo, Vooov, Voovv, Vovov, Vovvv, Vvvvv = moint.oooo, moint.ooov, moint.oovv, moint.ovov, moint.ovvv, moint.vvvv
    @tensoropt (i=>x, j=>x, k=>x, l=>x, a=>10x, b=>10x, c=>10x, d=>10x) begin
        newT2[i,j,a,b] += Voovv[i,j,a,b]
        newT2[i,j,a,b] += T1[i,c]*T1[j,d]*Vvvvv[c,d,a,b]
        newT2[i,j,a,b] += T2[i,j,c,d]*Vvvvv[c,d,a,b]
        newT2[i,j,a,b] += T1[k,a]*T1[l,b]*Voooo[i,j,k,l]
        newT2[i,j,a,b] += T2[k,l,a,b]*Voooo[i,j,k,l]
        newT2[i,j,a,b] -= T1[i,c]*T1[j,d]*T1[k,a]*Vovvv[k,b,c,d]
        newT2[i,j,a,b] -= T1[i,c]*T1[j,d]*T1[k,b]*Vovvv[k,a,d,c]
        newT2[i,j,a,b] += T1[i,c]*T1[k,a]*T1[l,b]*Vooov[l,k,j,c]
        newT2[i,j,a,b] += T1[j,c]*T1[k,a]*T1[l,b]*Vooov[k,l,i,c]
        newT2[i,j,a,b] += T2[k,l,a,c]*T2[i,j,d,b]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += -2.0*T2[i,k,a,c]*T2[l,j,b,d]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += -2.0*T2[l,k,a,c]*T2[i,j,d,b]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += T2[k,i,a,c]*T2[l,j,d,b]*Voovv[l,k,c,d]
        newT2[i,j,a,b] += T2[i,k,a,c]*T2[l,j,b,d]*Voovv[l,k,c,d]
        newT2[i,j,a,b] += -2.0*T2[i,k,a,c]*T2[j,l,b,d]*Voovv[l,k,c,d]
        newT2[i,j,a,b] += T2[k,i,a,c]*T2[l,j,b,d]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += -2.0*T2[k,i,a,c]*T2[j,l,b,d]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += T2[i,j,a,c]*T2[l,k,b,d]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += -2.0*T2[i,j,a,c]*T2[k,l,b,d]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += T2[k,j,a,c]*T2[i,l,d,b]*Voovv[l,k,c,d]
        newT2[i,j,a,b] += 4.0*T2[i,k,a,c]*T2[j,l,b,d]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += T2[i,j,d,c]*T2[l,k,a,b]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += T1[i,c]*T1[j,d]*T1[k,a]*T1[l,b]*Voovv[k,l,c,d]
        newT2[i,j,a,b] += T1[i,c]*T1[j,d]*T2[l,k,a,b]*Voovv[l,k,c,d]
        newT2[i,j,a,b] += T1[k,a]*T1[l,b]*T2[i,j,d,c]*Voovv[l,k,c,d]
        P_OoVv[i,j,a,b] := -1.0*foo[i,k]*T2[k,j,a,b]
        P_OoVv[i,j,a,b] += fvv[c,a]*T2[i,j,c,b]
        P_OoVv[i,j,a,b] += -1.0*T1[k,b]*Vooov[j,i,k,a]
        P_OoVv[i,j,a,b] += T1[j,c]*Vovvv[i,c,a,b]
        P_OoVv[i,j,a,b] += -1.0*fov[k,c]*T1[i,c]*T2[k,j,a,b]
        P_OoVv[i,j,a,b] += -1.0*fov[k,c]*T1[k,a]*T2[i,j,c,b]
        P_OoVv[i,j,a,b] += -1.0*T2[k,i,a,c]*Voovv[k,j,c,b]
        P_OoVv[i,j,a,b] += -1.0*T1[i,c]*T1[k,a]*Voovv[k,j,c,b]
        P_OoVv[i,j,a,b] += -1.0*T1[i,c]*T1[k,b]*Vovov[j,c,k,a]
        P_OoVv[i,j,a,b] += 2.0*T2[i,k,a,c]*Voovv[k,j,c,b]
        P_OoVv[i,j,a,b] += -1.0*T2[i,k,a,c]*Vovov[j,c,k,b]
        P_OoVv[i,j,a,b] += -1.0*T2[k,j,a,c]*Vovov[i,c,k,b]
        P_OoVv[i,j,a,b] += -2.0*T1[l,b]*T2[i,k,a,c]*Vooov[l,k,j,c]
        P_OoVv[i,j,a,b] += T1[l,b]*T2[k,i,a,c]*Vooov[l,k,j,c]
        P_OoVv[i,j,a,b] += -1.0*T1[j,c]*T2[i,k,d,b]*Vovvv[k,a,c,d]
        P_OoVv[i,j,a,b] += -1.0*T1[j,c]*T2[k,i,a,d]*Vovvv[k,b,d,c]
        P_OoVv[i,j,a,b] += -1.0*T1[j,c]*T2[i,k,a,d]*Vovvv[k,b,c,d]
        P_OoVv[i,j,a,b] += T1[j,c]*T2[l,k,a,b]*Vooov[l,k,i,c]
        P_OoVv[i,j,a,b] += T1[l,b]*T2[i,k,a,c]*Vooov[k,l,j,c]
        P_OoVv[i,j,a,b] += -1.0*T1[k,a]*T2[i,j,d,c]*Vovvv[k,b,d,c]
        P_OoVv[i,j,a,b] += T1[k,a]*T2[i,l,c,b]*Vooov[l,k,j,c]
        P_OoVv[i,j,a,b] += 2.0*T1[j,c]*T2[i,k,a,d]*Vovvv[k,b,d,c]
        P_OoVv[i,j,a,b] += -1.0*T1[k,c]*T2[i,j,a,d]*Vovvv[k,b,d,c]
        P_OoVv[i,j,a,b] += 2.0*T1[k,c]*T2[i,j,a,d]*Vovvv[k,b,c,d]
        P_OoVv[i,j,a,b] += T1[k,c]*T2[i,l,a,b]*Vooov[k,l,j,c]
        P_OoVv[i,j,a,b] += -2.0*T1[k,c]*T2[i,l,a,b]*Vooov[l,k,j,c]
        P_OoVv[i,j,a,b] += T2[j,k,c,d]*T2[i,l,a,b]*Voovv[k,l,c,d]
        P_OoVv[i,j,a,b] += -2.0*T1[k,c]*T1[j,d]*T2[i,l,a,b]*Voovv[k,l,c,d]
        P_OoVv[i,j,a,b] += T1[k,c]*T1[j,d]*T2[i,l,a,b]*Voovv[l,k,c,d]
        P_OoVv[i,j,a,b] += -2.0*T1[k,c]*T1[l,a]*T2[i,j,d,b]*Voovv[k,l,c,d]
        P_OoVv[i,j,a,b] += T1[k,c]*T1[l,a]*T2[i,j,d,b]*Voovv[l,k,c,d]
        P_OoVv[i,j,a,b] += T1[i,c]*T1[k,a]*T2[l,j,b,d]*Voovv[k,l,c,d]
        P_OoVv[i,j,a,b] += -2.0*T1[i,c]*T1[k,a]*T2[j,l,b,d]*Voovv[k,l,c,d]
        P_OoVv[i,j,a,b] += T1[i,c]*T1[k,a]*T2[l,j,d,b]*Voovv[l,k,c,d]
        P_OoVv[i,j,a,b] += T1[i,c]*T1[l,b]*T2[k,j,a,d]*Voovv[k,l,c,d]
        P_OoVv[i,j,a,b] += -2.0*T2[i,k,d,c]*T2[l,j,a,b]*Voovv[k,l,c,d]
        
        newT2[i,j,a,b] += P_OoVv[i,j,a,b] + P_OoVv[j,i,b,a]
    end
end