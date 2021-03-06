VERSION >= v"0.4.0-dev+6521" && __precompile__(true)

module IPNets
using Compat
import Base: IPAddr, IPv4, IPv6, parseipv4, parseipv6
import Base: length, size, endof, minimum, maximum, extrema, isless
import Base: in, contains, issubset, getindex
import Base: show, string, start, next

export
    # types
    IPNet, IPv4Net, IPv6Net, netmask


IPv4broadcast = typemax(UInt32)
IPv6broadcast = typemax(UInt128)

##################################################
# IPNet
##################################################

width(::Type{IPv4}) = @compat(UInt8(32))
width(::Type{IPv6}) = @compat(UInt8(128))

function _contiguousbitcount(n::Integer,t=UInt32)
    # takes an integer from 0 to 255 and a type, returns the number
    # of contiguous 1 bits in the number assuming it's of that type,
    # starting from the left.
    # cbc(240,UInt8) == 0x04 ("1111 0000")
    # cbc(252,UInt8) == 0x06 ("1111 1100")
    # cbc(127,UInt8) == error ("0111 1111")

    n = convert(t,n)
    invn = ~n
    bitct = log2(invn + 1)
    isinteger(bitct) || error("noncontiguous bits")

    bitct = @compat(floor(Int,bitct))
    return @compat(UInt8(sizeof(t)*8 - bitct))
end


function _mask2bits(t::Type, n::Unsigned)
    # takes a number of 1's bits in a
    # netmask and returns an integer representation
    maskbits = @compat(Int(width(t))) - @compat(Int(n))
    maskbits < 0 && throw(BoundsError())

    return (~(@compat(UInt128(2))^maskbits-1))
end


##################################################
# Network representations
##################################################
abstract IPNet

"""Returns the size of an IP network (# of hosts) as a tuple.
"""
function size(net::IPNet)
    numbits = width(typeof(net.netaddr)) - net.netmask
    return (big(2)^numbits, )
end

"""Returns the size of an IP network (# of hosts) as a tuple.
"""
length(net::IPNet) = size(net)[1]

"""String representation of an IP network"""
function string(net::IPNet)
    t = typeof(net)
    s = string("$t(\"")
    s = string(s, net.netaddr, "/", net.netmask, "\")")
    return s
end

function show(io::IO, net::IPNet)
    print(io, string(net))
end


# IP Networks are ordered first by starting network address
# and then by network mask. That is, smaller IP nets (with higher
# netmask values) are "less" than larger ones. This corresponds
# to secondary reordering by ending address.
function isless{T<:IPNet}(a::T, b::T)
    if a.netaddr == b.netaddr
        return isless(b.netmask, a.netmask)
    else
        return isless(a.netaddr, b.netaddr)
    end
end

function issubset{T<:IPNet}(a::T, b::T)
    astart, aend = extrema(a)
    bstart, bend = extrema(b)
    return (bstart <= astart <= aend <= bend)
end

"""Membership test for an IP address within an IP network"""
function in(ipaddr::IPAddr, net::IPNet)
    typeof(net.netaddr) == typeof(ipaddr) ||
        error("IPAddr is not the same type as IPNet")

    netstart = net.netaddr.host
    numbits = width(typeof(ipaddr)) - net.netmask
    netend = net.netaddr.host + big(2)^numbits - 1
    return netstart <= ipaddr.host <= netend
end

"""Membership test for an IP address within an IP network"""
function contains(net::IPNet, ipaddr::IPAddr)
    return in(ipaddr, net)
end


function getindex(net::IPNet, i::Integer)

    t = typeof(net.netaddr)
    ip = t(net.netaddr.host + i - 1)
    ip in net || throw(BoundsError())
    return ip
end


# Vector look-alikes
endof(net::IPNet) = @compat(UInt128(length(net)))
minimum(net::IPNet) = net[1]
maximum(net::IPNet) = net[end]
extrema(net::IPNet) = (minimum(net), maximum(net))
getindex(net::IPNet, r::Range) = [net[i] for i in r]
# getindex(net::IPNet, i::(Integer,)) = getindex(net,i[1])
start(net::IPNet) = net[1]
next{T<:IPAddr}(net::IPNet, s::T) = s, T(s.host + 1)
##################################################
# IPv4
##################################################

"""Type representing an IPv4 network"""
immutable IPv4Net <: IPNet
    netaddr::IPv4
    netmask::UInt8
    function IPv4Net(na::IPv4, nmi::Integer)
        (0 <= nmi <= width(IPv4)) || error("Invalid netmask")

        nm = @compat(UInt8(nmi))
        mask = _mask2bits(IPv4, nm)
        startip = @compat(UInt32(na.host & mask))
        new(IPv4(startip),nm)
    end
end


# "1.2.3.0/24"
function IPv4Net(ipmask::AbstractString)
    if search(ipmask,'/') > 0
        addrstr, netmaskstr = split(ipmask,"/")
        netmask = @compat(parse(UInt8,netmaskstr))
    else
        addrstr = ipmask
        netmask = width(IPv4)
    end
    netaddr = IPv4(addrstr)
    return IPv4Net(netaddr,netmask)
end


# "1.2.3.0", "255.255.255.0"
function IPv4Net(netaddr::AbstractString, netmask::AbstractString)
    netaddr = IPv4(netaddr).host
    netmask = _contiguousbitcount(IPv4(netmask).host)
    return IPv4Net(netaddr, netmask)
end


# 123872, 24
IPv4Net(ipaddr::Integer, netmask::Integer) = IPv4Net(IPv4(ipaddr), netmask)


# "(x,y)"
IPv4Net{A,M}(tuple::@compat(Tuple{A,M})) = IPv4Net(tuple[1],tuple[2])


# "1.2.3.0", 24
IPv4Net(netaddr::AbstractString, netmask::Integer) = IPv4Net(IPv4(netaddr), netmask)

"""Returns the netmask as an IPv4 address"""
netmask(n::IPv4Net) = IPv4(IPv4broadcast-2^(32-n.netmask)+1)


##################################################
# IPv6
##################################################

"""Type representing an IPv6 network"""
immutable IPv6Net <: IPNet
    # we treat the netmask as a potentially noncontiguous bitmask
    # for speed of calculation and consistency, but RFC2373, section
    # 2 provides for contiguous bitmasks only. We validate this
    # in the internal constructor. This wastes ~15 bytes per addr
    # for the benefit of rapid, consistent computation.
    netaddr::IPv6
    netmask::UInt32

    function IPv6Net(na::IPv6, nmi::Integer)
        (0 <= nmi <= width(IPv6)) || error("Invalid netmask")

        nm = @compat(UInt8(nmi))
        mask = _mask2bits(IPv6, nm)
        startip = @compat(UInt128(na.host & mask))
        return new(IPv6(startip), nm)
    end
end


# "2001::1/64"
function IPv6Net(ipmask::AbstractString)
    if search(ipmask,'/') > 0
        addrstr, netmaskbits = split(ipmask,"/")
        nmi = @compat(parse(Int,netmaskbits))
    else
        addrstr = ipmask
        nmi = width(IPv6)
    end
    netaddr = IPv6(addrstr)
    netmask = nmi
    return IPv6Net(netaddr,netmask)
end


# "2001::1", 64
function IPv6Net(netaddr::AbstractString, netmask::Integer)
    netaddr = IPv6(netaddr)
    return IPv6Net(netaddr, netmask)
end


# 123872, 128
IPv6Net(ipaddr::Integer, netmask::Integer) = IPv6Net(IPv6(ipaddr), netmask)


# (123872, 128)
IPv6Net{A,M}(tuple::@compat(Tuple{A,M})) = IPv6Net(tuple[1],tuple[2])

end
