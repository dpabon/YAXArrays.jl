module ESDLTools
using Distributed
import ..ESDL: ESDLdir
export mypermutedims!, freshworkermodule, passobj, @everywhereelsem,
toRange, getiperm, CItimes, CIdiv, @loadOrGenerate, PickAxisArray
struct PickAxisArray{T,N,AT<:AbstractArray,P,NCOL}
    parent::AT
end

function PickAxisArray(parent, indmask; ncol=0)
    @assert sum(indmask)+ncol==ndims(parent)
    f  = findall(indmask)
    PickAxisArray{eltype(parent),length(indmask),typeof(parent),(f...,),ncol}(parent)
end
indmask(p::PickAxisArray{<:Any,<:Any,<:Any,i,<:Any}) where i = i
getncol(p::PickAxisArray{<:Any,<:Any,<:Any,<:Any,NCOL}) where NCOL = NCOL
function Base.view(p::PickAxisArray, i...)
    inew = map(j->i[j],indmask(p))
    cols = ntuple(_ -> Colon(), getncol(p))
    view(p.parent,cols...,inew...)
end
function Base.getindex(p::PickAxisArray, i...)
    inew = map(j->i[j],indmask(p))
    cols = ntuple(_ -> Colon(), getncol(p))
    getindex(p.parent,cols...,inew...)
end
Base.getindex(p::PickAxisArray,i::CartesianIndex) = p[i.I...]
function newparent(a::PickAxisArray{T,N,AT,P,NCOL},parent) where {T,N,AT,P,NCOL}
  eltype(parent) == T || error("Types do not match")
  size(parent) == size(a.parent) || error("Sizes do not match")
  PickAxisArray{T,N,AT,P,NCOL}(parent)
end


function getiperm(perm)
    iperm = Array{Int}(undef,length(perm))
    for i = 1:length(perm)
        iperm[perm[i]] = i
    end
    return ntuple(i->iperm[i],length(iperm))
end

using Base.Cartesian
@generated function mypermutedims!(dest::AbstractArray{T,N},src::AbstractArray{S,N},perm::Type{Q}) where {Q,T,S,N}
    ind1=ntuple(i->Symbol("i_",i),N)
    ind2=ntuple(i->Symbol("i_",perm.parameters[1].parameters[1][i]),N)
    ex1=Expr(:ref,:src,ind1...)
    ex2=Expr(:ref,:dest,ind2...)
    quote
        @nloops $N i src begin
            $ex2=$ex1
        end
    end
end

@generated function CIdiv(index1::CartesianIndex{N}, index2::CartesianIndex{N}) where N
    I = index1
    args = [:(Base.div(index1[$d],index2[$d])) for d = 1:N]
    :($I($(args...)))
end
@generated function CItimes(index1::CartesianIndex{N}, index2::CartesianIndex{N}) where N
    I = index1
    args = [:(.*(index1[$d],index2[$d])) for d = 1:N]
    :($I($(args...)))
end

@generated function Base.getindex(t::NTuple{N},p::NTuple{N,Int}) where N
    :(@ntuple $N d->t[p[d]])
end

toRange(r::CartesianIndices)=map(colon,r.start.I,r.stop.I)
toRange(c1::CartesianIndex,c2::CartesianIndex)=map(colon,c1.I,c2.I)

function passobj(src::Int, target::Vector{Int}, nm::Symbol;
                 from_mod=Main, to_mod=Main)
    r = RemoteChannel(src)
    @spawnat(src, put!(r, getfield(from_mod, nm)))
    @sync for to in target
        @spawnat(to, Core.eval(to_mod, Expr(:(=), nm, fetch(r))))
    end
    nothing
end


function passobj(src::Int, target::Int, nm::Symbol; from_mod=Main, to_mod=Main)
    passobj(src, [target], nm; from_mod=from_mod, to_mod=to_mod)
end


function passobj(src::Int, target, nms::Vector{Symbol};
                 from_mod=Main, to_mod=Main)
    for nm in nms
        passobj(src, target, nm; from_mod=from_mod, to_mod=to_mod)
    end
end

function sendto(p::Int; args...)
    for (nm, val) in args
        @spawnat(p, Core.eval(Main, Expr(:(=), nm, val)))
    end
end


function sendto(ps::Vector{Int}; args...)
    for p in ps
        sendto(p; args...)
    end
end

getfrom(p::Int, nm::Symbol; mod=Main) = fetch(@spawnat(p, getfield(mod, nm)))


function freshworkermodule()
    in(:PMDATMODULE,names(Main)) || Core.eval(Main,:(module PMDATMODULE
        using ESDL
        using Distributed
    end))
    Core.eval(Main,quote
      using Distributed
      rs=Future[]
      for pid in workers()
        n=remotecall_fetch(()->in(:PMDATMODULE,names(Main)),pid)
        if !n
          r1=remotecall(()->(Core.eval(Main,:(using ESDL, Distributed));nothing),pid)
          r2=remotecall(()->(Core.eval(Main,:(module PMDATMODULE
          using ESDL
          using Distributed
        end));nothing),pid)
          push!(rs,r1)
          push!(rs,r2)
        end
      end
      [wait(r) for r in rs]
  end)

  nothing
end

import Distributed: extract_imports, remotecall_eval
macro everywhereelsem(ex)
  modu=:(Main.PMDATMODULE)
  procs = :(workers())
  imps = [Expr(:import, m) for m in extract_imports(ex)]
  return quote
    p = $(esc(procs))
    if p!=[1]
      $(isempty(imps) ? nothing : Expr(:toplevel, imps...)) # run imports locally first
      let ex = $(Expr(:quote, ex)), procs = p, mo=$(esc(modu))
        remotecall_eval(mo, procs, ex)
      end
    end
  end
end

"""
    macro loadOrGenerate(x...,expression)

Takes a list of `variablename=>"Storage Name"` pairs. Checks if all datasets can be found
on disk and loads them. If not, the datasets will be regenerated by evaluating the given expression.

To force recalculation, call `ESDL.recalculate(true)` before evaluating the macro.

### Example

The following lines will check if cubes with the names "Filled" and "Normalized"
exist on disk, load them and assign the variable names `cube_filled` and `cube_norm`.
If the datasets to not exist on disk, they are generated and saved under the given names.

````julia
@loadOrGenerate cube_filled=>"Filled" cube_norm=>"Normalized" begin
cube_filled = mapCube(gapFillMSC,d)
cube_norm   = mapCube(normalize_TS,d)
end

````
"""
macro loadOrGenerate(x...)
  code=x[end]
  x=x[1:end-1]
  x2=map(x) do i
    isa(i,Symbol) ? (i,string(i)) : (i.head==:call && i.args[1]==:(=>)) ? (i.args[2],i.args[3]) : error("Wrong Argument type")
  end
  xnames=map(i->i[2],x2)
  loadEx=map(x2) do i
    :($(i[1]) = loadcube($(i[2])))
  end
  loadEx=Expr(:block,loadEx...)
  saveEx=map(x2) do i
    :(savecube($(i[1]),$(i[2])))
  end
  saveEx=Expr(:block,saveEx...)
  rmEx=map(x2) do i
    :(rmcube($(i[2])))
  end
  rmEx=Expr(:block,rmEx...)
  esc(quote
    if !ESDL.recalculate() && all(i->isdir(joinpath(ESDLdir(),i)),$xnames)
      $loadEx
    else
      $rmEx
      $code
      $saveEx
    end
  end)
end
end
