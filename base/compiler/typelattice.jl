# This file is a part of Julia. License is MIT: https://julialang.org/license

#####################
# structs/constants #
#####################

# N.B.: Const/PartialStruct/InterConditional are defined in Core, to allow them to be used
# inside the global code cache.
#
# # The type of a value might be constant
# struct Const
#     val
# end
#
# struct PartialStruct
#     typ
#     fields::Vector{Any} # elements are other type lattice members
# end
import Core: Const, PartialStruct

# The type of this value might be Bool.
# However, to enable a limited amount of back-propagation,
# we also keep some information about how this Bool value was created.
# In particular, if you branch on this value, then may assume that in
# the true branch, the type of `var` will be limited by `vtype` and in
# the false branch, it will be limited by `elsetype`. Example:
# ```
# cond = isa(x::Union{Int, Float}, Int)::Conditional(x, Int, Float)
# if cond
#    # May assume x is `Int` now
# else
#    # May assume x is `Float` now
# end
# ```
# NOTE this lattice element is only used in abstractinterpret, not in optimization
struct Conditional
    var::SlotNumber
    vtype
    elsetype
    function Conditional(
                var::SlotNumber,
                @nospecialize(vtype),
                @nospecialize(elsetype))
        # avoid to be a slot wrapper of a slot wrapper (hard to maintain)
        vtype    = widenslotwrapper(vtype)
        elsetype = widenslotwrapper(elsetype)
        return new(var, vtype, elsetype)
    end
end

# # Similar to `Conditional`, but conveys inter-procedural constraints imposed on call arguments.
# # This is separate from `Conditional` to catch logic errors: the lattice element name is InterConditional
# # while processing a call, then Conditional everywhere else. Thus InterConditional does not appear in
# # CompilerTypes—these type's usages are disjoint—though we define the lattice for InterConditional.
# struct InterConditional
#     slot::Int
#     vtype
#     elsetype
# end
import Core: InterConditional
const AnyConditional = Union{Conditional,InterConditional}

# If an object field reference can be aliased to another reference of the same object field,
# this lattice element records the object identity and wraps the field type. It then allows
# certain built-in functions like `isa` and `===` to propagate a constraint imposed on the
# field when `MustAlias` appears at a call-site.
# This lattice element assumes the invariant that the field of wrapped slot object never
# changes until the slot object is re-assigned. This means, the wrapped object should be
# immutable since currently inference doesn't track any effects from memory writes.
# `has_const_field` takes the lift to check if a given lattice element is eligible to be
# wrapped by `MustAlias`.
# NOTE currently this lattice element is only used in abstractinterpret, not in optimization
struct MustAlias
    var::SlotNumber
    vartyp::Any
    fld::Const
    fldtyp::Any
    function MustAlias(
                var::SlotNumber,
                @nospecialize(vartyp),
                fld::Const,
                @nospecialize(fldtyp))
        # avoid to be a slot wrapper of a slot wrapper (hard to maintain)
        fldtyp = widenslotwrapper(fldtyp)
        return new(var, vartyp, fld, fldtyp)
    end
end

# This lattice element is very similar to `InterConditional`, but corresponds to `MustAlias`
# struct InterMustAlias
#     slot::Int
#     fld::Const
#     fldtyp::Any
# end
import Core: InterMustAlias
const AnyMustAlias = Union{MustAlias,InterMustAlias}

# XXX are these check really enough to hold invariants that `MustAlias` expects ?
function has_const_field(@nospecialize(objtyp))
    t = widenconst(objtyp)
    cnt = fieldcount_noerror(t)
    (cnt === nothing || cnt == 0) && return false
    return !ismutabletype(t)
end

@inline function validate_mustalias(alias::MustAlias, sv::InferenceState)
    (; var, vartyp) = alias
    varstate = sv.stmt_types[sv.currpc][slot_id(var)]::VarState
    # if the following assertion errors, it means `MustAlias` hasn't been invalidated upon
    # a re-assignment of the slot object, review `stupdate!`s
    @assert vartyp === varstate.typ "invalid MustAlias found"
end

function form_alias_condition(alias::MustAlias, @nospecialize(thentype), @nospecialize(elsetype))
    (; var, vartyp, fld) = alias
    vartyp_widened = widenconst(vartyp)
    # NOTE `has_const_field` assured this `fieldindex` to succeed aforehand
    idx = isa(fld.val, Int) ? fld.val : fieldindex(vartyp_widened, fld.val::Symbol)
    if isa(vartyp, PartialStruct)
        fields = vartyp.fields
        thenfields = thentype === Bottom ? nothing : copy(fields)
        elsefields = elsetype === Bottom ? nothing : copy(fields)
        for i in 1:length(fields)
            if i == idx
                thenfields === nothing || (thenfields[i] = thentype)
                elsefields === nothing || (elsefields[i] = elsetype)
            end
        end
        return Conditional(var,
                           thenfields === nothing ? Bottom : PartialStruct(vartyp.typ, thenfields),
                           elsefields === nothing ? Bottom : PartialStruct(vartyp.typ, elsefields))
    else
        thenfields = thentype === Bottom ? nothing : Any[]
        elsefields = elsetype === Bottom ? nothing : Any[]
        for i in 1:fieldcount(vartyp_widened)
            if i == idx
                thenfields === nothing || push!(thenfields, thentype)
                elsefields === nothing || push!(elsefields, elsetype)
            else
                t = fieldtype(vartyp_widened, i)
                thenfields === nothing || push!(thenfields, t)
                elsefields === nothing || push!(elsefields, t)
            end
        end
        return Conditional(var,
                           thenfields === nothing ? Bottom : PartialStruct(vartyp_widened, thenfields),
                           elsefields === nothing ? Bottom : PartialStruct(vartyp_widened, elsefields))
    end
end

struct PartialTypeVar
    tv::TypeVar
    # N.B.: Currently unused, but would allow turning something back
    # into Const, if the bounds are pulled out of this TypeVar
    lb_certain::Bool
    ub_certain::Bool
    PartialTypeVar(tv::TypeVar, lb_certain::Bool, ub_certain::Bool) = new(tv, lb_certain, ub_certain)
end

# Wraps a type and represents that the value may also be undef at this point.
# (only used in optimize, not abstractinterpret)
# N.B. in the lattice, this is epsilon bigger than `typ` (even Any)
struct MaybeUndef
    typ
    MaybeUndef(@nospecialize(typ)) = new(typ)
end

struct StateUpdate
    var::SlotNumber
    vtype::VarState
    state::VarTable
    conditional::Bool
end

# Represent that the type estimate has been approximated, due to "causes"
# (only used in abstract interpretion, doesn't appear in optimization)
# N.B. in the lattice, this is epsilon smaller than `typ` (except Union{})
struct LimitedAccuracy
    typ
    causes::IdSet{InferenceState}
    function LimitedAccuracy(@nospecialize(typ), causes::IdSet{InferenceState})
        @assert !isa(typ, LimitedAccuracy) "malformed LimitedAccuracy"
        return new(typ, causes)
    end
end

"""
    struct NotFound end
    const NOT_FOUND = NotFound()

A special sigleton that represents a variable has not been analyzed yet.
Particularly, all SSA value types are initialized as `NOT_FOUND` when creating a new `InferenceState`.
Note that this is only used for `smerge`, which updates abstract state `VarTable`,
and thus we don't define the lattice for this.
"""
struct NotFound end

const NOT_FOUND = NotFound()

const CompilerTypes = Union{MaybeUndef, Const, Conditional, MustAlias, NotFound, PartialStruct}
==(x::CompilerTypes, y::CompilerTypes) = x === y
==(x::Type, y::CompilerTypes) = false
==(x::CompilerTypes, y::Type) = false

#################
# lattice logic #
#################

# `Conditional` and `InterConditional` are valid in opposite contexts
# (i.e. local inference and inter-procedural call), as such they will never be compared
function issubconditional(a::C, b::C) where {C<:AnyConditional}
    if is_same_conditionals(a, b)
        if a.vtype ⊑ b.vtype
            if a.elsetype ⊑ b.elsetype
                return true
            end
        end
    end
    return false
end

is_same_conditionals(a::Conditional,      b::Conditional)      = slot_id(a.var) === slot_id(b.var)
is_same_conditionals(a::InterConditional, b::InterConditional) = a.slot === b.slot

is_lattice_bool(@nospecialize(typ)) = typ !== Bottom && typ ⊑ Bool

maybe_extract_const_bool(c::Const) = (val = c.val; isa(val, Bool)) ? val : nothing
function maybe_extract_const_bool(c::AnyConditional)
    (c.vtype === Bottom && !(c.elsetype === Bottom)) && return false
    (c.elsetype === Bottom && !(c.vtype === Bottom)) && return true
    nothing
end
maybe_extract_const_bool(@nospecialize c) = nothing

function issubalias(a::AnyMustAlias, b::AnyMustAlias)
    if is_same_aliases(a, b)
        return widenmustalias(a) ⊑ widenmustalias(b)
    end
    return false
end

is_same_aliases(a::MustAlias,      b::MustAlias)      = slot_id(a.var) == slot_id(b.var) && a.fld === b.fld
is_same_aliases(a::InterMustAlias, b::InterMustAlias) = a.slot         == b.slot         && a.fld === b.fld

"""
    a ⊑ b -> Bool

The non-strict partial order over the type inference lattice.
"""
@nospecialize(a) ⊑ @nospecialize(b) = begin
    if isa(b, LimitedAccuracy)
        if !isa(a, LimitedAccuracy)
            return false
        end
        if b.causes ⊈ a.causes
            return false
        end
        b = b.typ
    end
    isa(a, LimitedAccuracy) && (a = a.typ)
    if isa(a, MaybeUndef) && !isa(b, MaybeUndef)
        return false
    end
    isa(a, MaybeUndef) && (a = a.typ)
    isa(b, MaybeUndef) && (b = b.typ)
    b === Any && return true
    a === Any && return false
    a === Union{} && return true
    b === Union{} && return false
    @assert !isa(a, TypeVar) "invalid lattice item"
    @assert !isa(b, TypeVar) "invalid lattice item"
    if isa(a, AnyConditional)
        if isa(b, AnyConditional)
            return issubconditional(a, b)
        elseif isa(b, Const) && isa(b.val, Bool)
            return maybe_extract_const_bool(a) === b.val
        end
        a = Bool
    elseif isa(b, AnyConditional)
        return false
    end
    if isa(a, AnyMustAlias)
        if isa(b, AnyMustAlias)
            return issubalias(a, b)
        end
        a = widenmustalias(a)
    elseif isa(b, AnyMustAlias)
        return a ⊑ widenmustalias(b)
    end
    if isa(a, PartialStruct)
        if isa(b, PartialStruct)
            if !(length(a.fields) == length(b.fields) && a.typ <: b.typ)
                return false
            end
            for i in 1:length(b.fields)
                # XXX: let's handle varargs later
                ⊑(a.fields[i], b.fields[i]) || return false
            end
            return true
        end
        return isa(b, Type) && a.typ <: b
    elseif isa(b, PartialStruct)
        if isa(a, Const)
            nfields(a.val) == length(b.fields) || return false
            widenconst(b).name === widenconst(a).name || return false
            # We can skip the subtype check if b is a Tuple, since in that
            # case, the ⊑ of the elements is sufficient.
            if b.typ.name !== Tuple.name && !(widenconst(a) <: widenconst(b))
                return false
            end
            for i in 1:nfields(a.val)
                # XXX: let's handle varargs later
                isdefined(a.val, i) || continue # since ∀ T Union{} ⊑ T
                ⊑(Const(getfield(a.val, i)), b.fields[i]) || return false
            end
            return true
        end
        return false
    end
    if isa(a, PartialOpaque)
        if isa(b, PartialOpaque)
            (a.parent === b.parent && a.source === b.source) || return false
            return (widenconst(a) <: widenconst(b)) &&
                ⊑(a.env, b.env)
        end
        return widenconst(a) ⊑ b
    end
    if isa(a, Const)
        if isa(b, Const)
            return a.val === b.val
        end
        # TODO: `b` could potentially be a `PartialTypeVar` here, in which case we might be
        # able to return `true` in more cases; in the meantime, just returning this is the
        # most conservative option.
        return isa(b, Type) && isa(a.val, b)
    elseif isa(b, Const)
        if isa(a, DataType) && isdefined(a, :instance)
            return a.instance === b.val
        end
        return false
    elseif isa(a, PartialTypeVar) && b === TypeVar
        return true
    elseif isa(a, Type) && isa(b, Type)
        return a <: b
    else # handle this conservatively in the remaining cases
        return a === b
    end
end

"""
    a ⊏ b -> Bool

The strict partial order over the type inference lattice.
This is defined as the irreflexive kernel of `⊑`.
"""
@nospecialize(a) ⊏ @nospecialize(b) = a ⊑ b && !⊑(b, a)

"""
    a ⋤ b -> Bool

This order could be used as a slightly more efficient version of the strict order `⊏`,
where we can safely assume `a ⊑ b` holds.
"""
@nospecialize(a) ⋤ @nospecialize(b) = !⊑(b, a)

# Check if two lattice elements are partial order equivalent. This is basically
# `a ⊑ b && b ⊑ a` but with extra performance optimizations.
function is_lattice_equal(@nospecialize(a), @nospecialize(b))
    a === b && return true
    if isa(a, PartialStruct)
        isa(b, PartialStruct) || return false
        length(a.fields) == length(b.fields) || return false
        widenconst(a) == widenconst(b) || return false
        for i in 1:length(a.fields)
            is_lattice_equal(a.fields[i], b.fields[i]) || return false
        end
        return true
    end
    isa(b, PartialStruct) && return false
    if a isa Const
        if issingletontype(b)
            return a.val === b.instance
        end
        return false
    end
    if b isa Const
        if issingletontype(a)
            return a.instance === b.val
        end
        return false
    end
    if isa(a, PartialOpaque)
        isa(b, PartialOpaque) || return false
        widenconst(a) == widenconst(b) || return false
        a.source === b.source || return false
        a.parent === b.parent || return false
        return is_lattice_equal(a.env, b.env)
    end
    return a ⊑ b && b ⊑ a
end

# compute typeintersect over the extended inference lattice,
# as precisely as we can,
# where v is in the extended lattice, and t is a Type.
function tmeet(@nospecialize(v), @nospecialize(t))
    if isa(v, Const)
        if !has_free_typevars(t) && !isa(v.val, t)
            return Bottom
        end
        return v
    elseif isa(v, PartialStruct)
        has_free_typevars(t) && return v
        widev = widenconst(v)
        if widev <: t
            return v
        end
        ti = typeintersect(widev, t)
        valid_as_lattice(ti) || return Bottom
        @assert widev <: Tuple
        new_fields = Vector{Any}(undef, length(v.fields))
        for i = 1:length(new_fields)
            vfi = v.fields[i]
            if isvarargtype(vfi)
                new_fields[i] = vfi
            else
                new_fields[i] = tmeet(vfi, widenconst(getfield_tfunc(t, Const(i))))
                if new_fields[i] === Bottom
                    return Bottom
                end
            end
        end
        return tuple_tfunc(new_fields)
    elseif isa(v, Conditional)
        if !(Bool <: t)
            return Bottom
        end
        return v
    end
    ti = typeintersect(widenconst(v), t)
    valid_as_lattice(ti) || return Bottom
    return ti
end

widenconst(::AnyConditional) = Bool
widenconst(a::AnyMustAlias) = widenconst(widenmustalias(a))
widenconst((; val)::Const) = isa(val, Type) ? Type{val} : typeof(val)
widenconst(m::MaybeUndef) = widenconst(m.typ)
widenconst(::PartialTypeVar) = TypeVar
widenconst(t::PartialStruct) = t.typ
widenconst(t::PartialOpaque) = t.typ
widenconst(t::Type) = t
widenconst(::TypeVar) = error("unhandled TypeVar")
widenconst(::TypeofVararg) = error("unhandled Vararg")
widenconst(::LimitedAccuracy) = error("unhandled LimitedAccuracy")

issubstate(a::VarState, b::VarState) = (a.typ ⊑ b.typ && a.undef <= b.undef)

function smerge(sa::Union{NotFound,VarState}, sb::Union{NotFound,VarState})
    sa === sb && return sa
    sa === NOT_FOUND && return sb
    sb === NOT_FOUND && return sa
    issubstate(sa, sb) && return sb
    issubstate(sb, sa) && return sa
    return VarState(tmerge(sa.typ, sb.typ), sa.undef | sb.undef)
end

@inline tchanged(@nospecialize(n), @nospecialize(o)) = o === NOT_FOUND || (n !== NOT_FOUND && !(n ⊑ o))
@inline schanged(@nospecialize(n), @nospecialize(o)) = (n !== o) && (o === NOT_FOUND || (n !== NOT_FOUND && !issubstate(n::VarState, o::VarState)))

function widenconditional(@nospecialize typ)
    if isa(typ, AnyConditional)
        if typ.vtype === Union{}
            return Const(false)
        elseif typ.elsetype === Union{}
            return Const(true)
        else
            return Bool
        end
    end
    return typ
end
widenconditional(::LimitedAccuracy) = error("unhandled LimitedAccuracy")

widenmustalias(@nospecialize typ) = typ
widenmustalias(typ::AnyMustAlias) = typ.fldtyp
widenmustalias(::LimitedAccuracy) = error("unhandled LimitedAccuracy")

widenslotwrapper(@nospecialize t)   = t
widenslotwrapper(t::AnyMustAlias)   = widenmustalias(t)
widenslotwrapper(t::AnyConditional) = widenconditional(t)
widenwrappedslotwrapper(@nospecialize typ)    = widenslotwrapper(typ)
widenwrappedslotwrapper(typ::LimitedAccuracy) = LimitedAccuracy(widenslotwrapper(typ.typ), typ.causes)
widenwrappedconditional(@nospecialize typ)    = widenconditional(typ)
widenwrappedconditional(typ::LimitedAccuracy) = LimitedAccuracy(widenconditional(typ.typ), typ.causes)

ignorelimited(@nospecialize typ) = typ
ignorelimited(typ::LimitedAccuracy) = typ.typ

function stupdate!(state::Nothing, changes::StateUpdate)
    newst = copy(changes.state)
    changeid = slot_id(changes.var)
    newst[changeid] = changes.vtype
    # remove any Conditional for this slot from the vtable
    # (unless this change is came from the conditional)
    for i = 1:length(newst)
        newtype = newst[i]
        if isa(newtype, VarState)
            newtypetyp = ignorelimited(newtype.typ)
            if (!changes.conditional && isa(newtypetyp, Conditional) && slot_id(newtypetyp.var) == changeid) ||
               (isa(newtypetyp, MustAlias) && slot_id(newtypetyp.var) == changeid)
                newtypetyp = widenwrappedslotwrapper(newtype.typ)
                newst[i] = VarState(newtypetyp, newtype.undef)
            end
        end
    end
    return newst
end

function stupdate!(state::VarTable, changes::StateUpdate)
    newstate = nothing
    changeid = slot_id(changes.var)
    for i = 1:length(state)
        if i == changeid
            newtype = changes.vtype
        else
            newtype = changes.state[i]
        end
        oldtype = state[i]
        # remove any Conditional for this slot from the vtable
        # (unless this change is came from the conditional)
        if isa(newtype, VarState)
            newtypetyp = ignorelimited(newtype.typ)
            if (!changes.conditional && isa(newtypetyp, Conditional) && slot_id(newtypetyp.var) == changeid) ||
               (isa(newtypetyp, MustAlias) && slot_id(newtypetyp.var) == changeid)
                newtypetyp = widenwrappedslotwrapper(newtype.typ)
                newtype = VarState(newtypetyp, newtype.undef)
            end
        end
        if schanged(newtype, oldtype)
            newstate = state
            state[i] = smerge(oldtype, newtype)
        end
    end
    return newstate
end

function stupdate!(state::VarTable, changes::VarTable)
    newstate = nothing
    for i = 1:length(state)
        newtype = changes[i]
        oldtype = state[i]
        if schanged(newtype, oldtype)
            newstate = state
            state[i] = smerge(oldtype, newtype)
        end
    end
    return newstate
end

stupdate!(state::Nothing, changes::VarTable) = copy(changes)

stupdate!(state::Nothing, changes::Nothing) = nothing

function stupdate1!(state::VarTable, change::StateUpdate)
    changeid = slot_id(change.var)
    # remove any Conditional for this slot from the catch block vtable
    # (unless this change is came from the conditional)
    for i = 1:length(state)
        oldtype = state[i]
        if isa(oldtype, VarState)
            oldtypetyp = ignorelimited(oldtype.typ)
            if (!change.conditional && isa(oldtypetyp, Conditional) && slot_id(oldtypetyp.var) == changeid) ||
               (isa(oldtypetyp, MustAlias) && slot_id(oldtypetyp.var) == changeid)
                oldtypetyp = widenwrappedslotwrapper(oldtype.typ)
                state[i] = VarState(oldtypetyp, oldtype.undef)
            end
        end
    end
    # and update the type of it
    newtype = change.vtype
    oldtype = state[changeid]
    if schanged(newtype, oldtype)
        state[changeid] = smerge(oldtype, newtype)
        return true
    end
    return false
end
