using Test
using Printf: @printf
using LinearAlgebra: tr
using StaticArrays: SVector
using QuantumLattices.Essentials.Frameworks
using QuantumLattices.Essentials: update!, reset!, register!
using QuantumLattices.Essentials.Spatials: Point, PID, Bond, Bonds, Lattice, acrossbonds, zerothbonds
using QuantumLattices.Essentials.DegreesOfFreedom: SimpleIID, SimpleInternal, IIDSpace, Coupling, Subscript, Subscripts, SubscriptsID
using QuantumLattices.Essentials.DegreesOfFreedom: Term, Hilbert, Index, Table, OID, OIDToTuple, Operator, Operators, plain, @couplings
using QuantumLattices.Essentials.QuantumOperators: ID, id, idtype, Identity
using QuantumLattices.Prerequisites: Float
using QuantumLattices.Interfaces:  expand!, expand
using QuantumLattices.Prerequisites.Traits: contentnames
using QuantumLattices.Prerequisites.CompositeStructures: NamedContainer

import QuantumLattices.Essentials.Frameworks: Parameters, dependences
import QuantumLattices.Essentials: prepare!, run!, update!
import QuantumLattices.Essentials.DegreesOfFreedom: isHermitian, couplingcenters
import QuantumLattices.Prerequisites.VectorSpaces: shape, ndimshape

struct FID{N<:Union{Int, Symbol}} <: SimpleIID
    nambu::N
end
@inline Base.adjoint(sl::FID{Int}) = FID(3-sl.nambu)

struct FFock <: SimpleInternal{FID{Int}}
    nnambu::Int
end
@inline shape(f::FFock) = (1:f.nnambu,)
@inline ndimshape(::Type{FFock}) = 1
@inline FID(i::CartesianIndex, vs::FFock) = FID(i.I...)
@inline CartesianIndex(did::FID{Int}, vs::FFock) = CartesianIndex(did.nambu)
@inline shape(iidspace::IIDSpace{FID{Symbol}, FFock}) = (1:iidspace.internal.nnambu,)
@inline shape(iidspace::IIDSpace{FID{Int}, FFock}) = (iidspace.iid.nambu:iidspace.iid.nambu,)
@inline shape(iidspace::IIDSpace{FID{Symbol}, FFock}) = (1:iidspace.internal.nnambu,)
@inline shape(iidspace::IIDSpace{FID{Int}, FFock}) = (iidspace.iid.nambu:iidspace.iid.nambu,)

const FCoupling{V, I<:ID{FID}, C<:Subscripts, CI<:SubscriptsID} = Coupling{V, I, C, CI}
@inline couplingcenters(::(Coupling{V, <:ID{FID}} where V), ::Bond, ::Val) = (1, 2)
@inline FCoupling(value, nambus::Tuple{Vararg{Int}}) = Coupling(value, ID(FID, nambus), Subscripts((nambu=Subscript(nambus),)))
@inline FCoupling(value, nambus::Subscript) = Coupling(value, ID(FID, convert(Tuple, nambus)), Subscripts((nambu=nambus,)))

@inline isHermitian(::Type{<:Term{:Mu}}) = true
@inline isHermitian(::Type{<:Term{:Hp}}) = false

struct FEngine <: Engine end
@inline Base.repr(::FEngine) = "FEngine"
@inline Base.show(io::IO, ::FEngine) = @printf io "FEngine"
struct FAction <: Action end

mutable struct VCA <: Engine
    t::Float
    U::Float
end
function update!(vca::VCA; kwargs...)
    vca.t = get(kwargs, :t, vca.t)
    vca.U = get(kwargs, :U, vca.U)
    return vca
end
@inline Parameters(vca::VCA) = Parameters{(:t, :U)}(vca.t, vca.U)
@inline gf(alg::Algorithm{VCA}) = get(alg, Val(:_VCAGF_)).data

mutable struct GF <: Action
    dim::Int
    count::Int
end

mutable struct DOS <: Action
    mu::Float
end
@inline update!(eb::DOS; kwargs...) = (eb.mu = get(kwargs, :mu, eb.mu); eb)

@inline dependences(alg::Algorithm{VCA}, assign::Assignment{GF}, ::Tuple{}=()) = assign.dependences
@inline dependences(alg::Algorithm{VCA}, assign::Assignment, ::Tuple{}=()) = (:_VCAGF_, assign.dependences...)
@inline function prepare!(alg::Algorithm{VCA}, assign::Assignment{GF})
    assign.virgin && (assign.data = Matrix{valtype(assign)|>eltype}(undef, assign.action.dim, assign.action.dim))
end
@inline run!(alg::Algorithm{VCA}, assign::Assignment{GF}) = (assign.action.count += 1; assign.data[:, :] .= alg.engine.t+alg.engine.U)
@inline function run!(alg::Algorithm{VCA}, assign::Assignment{DOS})
    rundependences!(alg, assign)
    assign.data = tr(gf(alg))
end

@testset "Parameters" begin
    ps1 = Parameters{(:t1, :t2, :U)}(1.0im, 1.0, 2.0)
    ps2 = Parameters{(:t1, :U)}(1.0im, 2.0)
    ps3 = Parameters{(:t1, :U)}(1.0im, 2.1)
    @test match(ps1, ps2) == true
    @test match(ps1, ps3) == false
end

@testset "Generator" begin
    @test contentnames(AbstractGenerator) == (:operators, :table, :boundary)

    lattice = Lattice("Tuanzi", [Point(PID(1), (0.0, 0.0), (0.0, 0.0)), Point(PID(2), (0.5, 0.0), (0.0, 0.0))], vectors=[[1.0, 0.0]], neighbors=1)
    bonds = Bonds(lattice)
    hilbert = Hilbert{FFock}(pid->FFock(2), lattice.pids)
    table = Table(hilbert, OIDToTuple(:scope, :site))
    t = Term{:Hp}(:t, 2.0, 1, couplings=@couplings(FCoupling(1.0, (2, 1))))
    μ = Term{:Mu}(:μ, 1.0, 0, couplings=@couplings(FCoupling(1.0, (2, 1))), modulate=true)
    tops₁ = expand(t, filter(acrossbonds, bonds, Val(:exclude)), hilbert, half=true, table=table)
    tops₂ = expand(one(t), filter(acrossbonds, bonds, Val(:include)), hilbert, half=true, table=table)
    μops = expand(one(μ), filter(zerothbonds, bonds, Val(:include)), hilbert, half=true, table=table)
    i = Identity()

    optp = Operator{Float, ID{OID{Index{PID, FID{Int}}, SVector{2, Float}}, 2}}
    entry = Entry(tops₁, NamedContainer{(:μ,)}((μops,)), NamedContainer{(:t, :μ)}((tops₂, Operators{optp|>idtype, optp}())))
    @test entry == deepcopy(entry) && isequal(entry, deepcopy(entry))
    @test entry == Entry((t, μ), bonds, hilbert, half=true, table=table)
    @test entry|>eltype == entry|>typeof|>eltype == Operators{idtype(optp), optp}
    @test expand!(Operators{idtype(optp), optp}(), entry, plain, t=2.0, μ=1.5) == tops₁+tops₂*2.0+μops*1.5
    @test empty(entry) == empty!(deepcopy(entry))
    @test empty(entry) == Entry(empty(μops), NamedContainer{(:μ,)}((empty(μops),)), NamedContainer{(:t, :μ)}((empty(μops), empty(μops))))
    @test merge!(empty(entry), entry) == merge(entry, entry) == entry
    @test reset!(deepcopy(entry), (t, μ), bonds, hilbert, half=true, table=table) == entry
    @test i(entry) == entry

    cgen = Generator((t, μ), bonds, hilbert; half=true, table=table, boundary=plain)
    @test cgen == deepcopy(cgen) && isequal(cgen, deepcopy(cgen))
    @test Parameters(cgen) == Parameters{(:t, :μ)}(2.0, 1.0)
    @test expand!(Operators{idtype(optp), optp}(), cgen) == expand(cgen) == tops₁+tops₂*2.0+μops
    @test expand(cgen, :t) == tops₁+tops₂*2.0
    @test expand(cgen, :μ) == μops
    @test expand(cgen, 1)+expand(cgen, 2)+expand(cgen, 3)+expand(cgen, 4) == expand(cgen)
    @test expand(cgen, :μ, 1)+expand(cgen, :μ, 2) == μops
    @test expand(cgen, :t, 3) == tops₁
    @test expand(cgen, :t, 4) == tops₂*2.0
    @test empty!(deepcopy(cgen)) == Generator((t, μ), empty(bonds), empty(hilbert), half=true, table=empty(table), boundary=plain) == empty(cgen)
    @test reset!(empty(cgen), lattice) == cgen
    @test update!(cgen, μ=1.5)|>expand == tops₁+tops₂*2.0+μops*1.5

    params = Parameters{(:t, :μ)}(2.0, 1.0)
    sgen = SimplifiedGenerator(params, entry, table=table, boundary=plain)
    @test Parameters(sgen) == params
    @test expand!(Operators{idtype(optp), optp}(), sgen) == expand(sgen) == tops₁+tops₂*2.0+μops
    @test empty!(deepcopy(sgen)) == SimplifiedGenerator(params, empty(entry), table=empty(table), boundary=plain) == empty(sgen)
    @test reset!(empty(sgen), entry, table=table) == sgen
    @test update!(sgen, μ=1.5)|>expand == tops₁+tops₂*2.0+μops*1.5
    @test i(cgen) == sgen
end

@testset "Assignment" begin
    @test FAction() == FAction()
    @test isequal(FAction(), FAction())
    @test update!(FAction()) == FAction()

    assign = Assignment(:FAction, FAction(), (t=1.0, U=8.0), dependences=(:FAction₁, :FAction₂))
    @test deepcopy(assign) == assign
    @test isequal(deepcopy(assign), assign)
    @test assign|>valtype == assign|>typeof|>valtype == Any
    @test assign|>id == assign|>typeof|>id == :FAction
    update!(assign, t=2.0)
    @test assign.parameters == (t=2.0, U=8.0)
end

@testset "Algorithm" begin
    @test FEngine() == FEngine()
    @test isequal(FEngine(), FEngine())
    @test update!(FEngine()) == FEngine()

    alg = Algorithm("Alg", FEngine(), parameters=(t=1.0, U=8.0))
    @test alg==alg
    @test isequal(alg, alg)
    @test string(alg) == repr(alg) == "Alg_FEngine_1.0_8.0"
    @test repr(alg, (:U,)) == "Alg_FEngine_1.0"
    @test_logs (:info, r"Action FAction₁\(FAction\)\: time consumed [0-9]*\.[0-9]*s.") register!(alg, :FAction₁, FAction(), parameters=(U=5.0,))
    @test_logs (:info, r"Action FAction₂\(FAction\)\: time consumed [0-9]*\.[0-9]*s.") register!(alg, :FAction₂, FAction(), parameters=(U=6.0,), dependences=(:FAction₁,))
    @test get(alg, Val(:FAction₁)) == get(alg, :FAction₁) == Assignment(:FAction₁, FAction(), (t=1.0, U=5.0), virgin=false)
    @test get(alg, Val(:FAction₂)) == get(alg, :FAction₂) == Assignment(:FAction₂, FAction(), (t=1.0, U=6.0), dependences=(:FAction₁,), virgin=false)
    @test isnothing(prepare!(alg, get(alg, :FAction₁)))
    @test isnothing(run!(alg, get(alg, :FAction₁)))
    @test dependences(alg, get(alg, :FAction₁)) == ()
    @test dependences(alg, get(alg, :FAction₂)) == (:FAction₁,)
    @test dependences(alg, get(alg, :FAction₂), (:FAction₁,)) == ()
end

@testset "Framework" begin
    engine = VCA(1.0, 8.0)
    gf = Assignment(:_VCAGF_, GF(4, 0), Parameters(engine), data=Matrix{Complex{Float}}(undef, 0, 0))
    vca = Algorithm("Test", engine, assignments=(gf,))
    @test_logs (:info, r"Action DOS\(DOS\)\: time consumed [0-9]*\.[0-9]*s.") register!(vca, :DOS, DOS(-3.5), parameters=(U=7.0,), map=params::Parameters->Parameters{(:t, :U, :mu)}(params.t, params.U, -params.U/2))
    dos = get(vca, :DOS)
    @test dos.data == 32.0
    @test dos.action.mu == -3.5
    update!(dos, U=6.0)
    run!(vca, :DOS, false)
    @test dos.data == 28.0
    @test dos.action.mu == -3.0
end
