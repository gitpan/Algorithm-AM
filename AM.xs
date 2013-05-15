#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

typedef unsigned short USHORT;
typedef unsigned long ULONG;

/*
 * structure for the supracontexts
 *
 */

typedef struct AM_supra {
  /* list of subcontexts in this supracontext
   *
   * data[0] is the number of subcontexts in
   * the array;
   *
   * data[1] is always 0 (useful for finding
   * intersections; see below)
   *
   * data[i] is not an actually subcontext
   * label; instead, all the subcontext labels
   * are kept in an array called subcontext
   * (bad choice of name?)  created in
   * function _fillandcount().  Thus, the
   * actual subcontexts in the supracontext
   * are subcontext[data[2]], ...
   *
   * data[i] < data[i+1] if i > 1 and
   * i < data[0].
   *
   * Using an array of increasing positive
   * integers makes it easy to take
   * intersections (see lattice.pod).
   */
  USHORT *data;

  /* number of supracontexts that contain
   * precisely these subcontexts;
   *
   * According to the AM algorithm, we're
   * supposed to look at all the homogeneous
   * supracontexts to compute the analogical
   * set.  Instead of traversing the
   * supracontextual lattice to find them, we
   * can instead traverse the list of AM_SUPRA
   * with count > 0 and use the value of count
   * to do our computing.
   *
   * Since we're actually traversing four
   * small lattices and taking intersections,
   * we'll be multiplying the four values of
   * count to get what we want.
   *
   */
  USHORT count;

  /*
   * used to implement two linked lists
   *
   * One linked list contains all the nonempty
   * supracontexts (i.e., data[0] is not 0).
   * This linked list is in fact circular.
   *
   * One linked list contains all the unused
   * memory that can be used for new
   * supracontexts.
   */
  USHORT next;

  /*
   * used during the filling of the
   * supracontextual lattice (see below)
   */
  unsigned char touched;
} AM_SUPRA;

/*
 * There is quite a bit of data that must pass between Parallel.pm and
 * Parallel.xs.  Instead of repeatedly passing it back and forth on
 * the argument stack, Parallel.pm sends references to the variables
 * holding this shared data, by calling _initialize() (defined later
 * on).  These pointers are then stored in the following structure,
 * which is put into the magic part of $self (since $self is an HV,
 * it is perforce an SvPVMG as well).
 *
 * Note that for arrays, we store a pointer to the array data itself,
 * not the AV*.  That means that in Parallel.pm, we have to be careful
 * how we make assignments to array variables; a reassignment such as
 *
 * @sum = (pack "L!8", 0, 0, 0, 0, 0, 0, 0, 0) x @sum;
 *
 * breaks everything because the pointer stored here then won't point
 * to the actual data anymore.  That's why the appropriate line in
 * Parallel.pm is
 *
 * foreach (@sum) {
 *   $_ = pack "L!8", 0, 0, 0, 0, 0, 0, 0, 0;
 * }
 *
 * Most of the identifiers in the struct have the same names as the
 * variables created in Parallel.pm and are documented there.  Those
 * that don't are documented below.
 *
 * This trick of storing pointers like this is borrowed from the
 * source code of Perl/Tk.  Thanks, Nick!
 *
 */

typedef struct AM_guts {

  /*
   * Let i be an integer from 0 to 3; this represents which of the
   * four sublattices we are considering.
   *
   * Let lattice = lptr[i] and supralist = sptr[i]; then lattice and
   * supralist taken together tell us which subcontexts are in a
   * particular supracontext.  If s is the label of a supracontext,
   * then it contains the subcontexts listed in
   * supralist[lattice[s]].data[].
   *
   */

  USHORT *lptr[4];
  AM_SUPRA *sptr[4];

  /* The rest of these come from Parallel.pm -- look there */

  SV **activeVar;
  SV **outcome;
  SV **itemcontextchain;
  HV *itemcontextchainhead;
  HV *subtooutcome;
  HV *contextsize;
  HV *pointers;
  HV *gang;
  SV **sum;

  /*
   * contains the total number of possible outcomes;
   * used below for computing gang effects
   */
  IV numoutcomes;
} AM_GUTS;

/*
 * A function and a vtable necessary for the use of Perl magic
 */

static int AMguts_mgFree(pTHX_ SV *sv, MAGIC *mg) {
  int i;
  AM_GUTS *guts = (AM_GUTS *) SvPVX(mg->mg_obj);
  for (i = 0; i < 4; ++i) {
    Safefree(guts->lptr[i]);
    Safefree(guts->sptr[i][0].data);
    Safefree(guts->sptr[i]);
  }
  return 0;
}

MGVTBL AMguts_vtab = {
  NULL,
  NULL,
  NULL,
  NULL,
  AMguts_mgFree
};

/*
 * This program must deal with integers that are too big to be
 * represented by 32 bits.
 *
 * They are represented by arrays as
 *
 * unsigned long a[8]
 *
 * where each a[i] < 2*16.  Such an array represents the integer
 *
 * a[0] + a[1] * 2^16 + ... + a[7] * 2^(7*16).
 *
 * We only use 16 bits of the unsigned long instead of 32, so that
 * when we add or multiply two large integers, we have room for overflow.
 * After any addition or multiplication, the result is normalized so that
 * each element of the array is again < 2*16.
 *
 * Someday I may rewrite this in assembler.
 *
 */

/*
 * arrays used in the change-of-base portion of normalize(SV *s)
 * they are initialized in BOOT
 *
 */

ULONG tens[16]; /* 10, 10*2, 10*4, ... */
ULONG ones[16]; /*  1,  1*2,  1*4, ... */

/*
 * function: normalize(SV *s)
 *
 * s is an SvPV whose PV* is a unsigned long array representing a very
 * large integer
 *
 * this function modifies s so that its NV is the floating point
 * representation of the very large integer value, while its PV* is
 * the decimal representation of the very large integer value in ASCII
 * (cool, a double-valued scalar)
 *
 * computing the NV is straightforward
 *
 * computing the PV is done using the old change-of-base algorithm:
 * repeatedly divide by 10, and use the remainders to construct the
 * ASCII digits from least to most significant
 *
 */

normalize(SV *s) {
  ULONG dspace[10];
  ULONG qspace[10];
  char outspace[55];
  ULONG *dividend, *quotient, *dptr, *qptr;
  char *outptr;
  unsigned int outlength = 0;
  ULONG *p = (ULONG *) SvPVX(s);
  STRLEN length = SvCUR(s) / sizeof(ULONG);
  long double nn = 0;
  int j;

  /* you can't put the for block in {}, or it doesn't work
   * ask me for details some time
   */
  for (j = 8; j; --j)
    nn = 65536.0 * nn + (double) *(p + j - 1);

  dividend = &dspace[0];
  quotient = &qspace[0];
  Copy(p, dividend, length, sizeof(ULONG));
  outptr = outspace + 54;

  while (1) {
    ULONG *temp, carry = 0;
    while (length && (*(dividend + length - 1) == 0)) --length;
    if (length == 0) {
      sv_setpvn(s, outptr, outlength);
      break;
    }
    dptr = dividend + length - 1;
    qptr = quotient + length - 1;
    while (dptr >= dividend) {
      unsigned int i;
      *dptr += carry << 16;
      *qptr = 0;
      for (i = 16; i; ) {
	--i;
	if (tens[i] <= *dptr) {
	  *dptr -= tens[i];
	  *qptr += ones[i];
	}
      }
      carry = *dptr;
      --dptr;
      --qptr;
    }
    --outptr;
    *outptr = (char) (0x30 + *dividend) & 0x00ff;
    ++outlength;
    temp = dividend;
    dividend = quotient;
    quotient = temp;
  }

  SvNVX(s) = nn;
  SvNOK_on(s);
}

MODULE = Algorithm::AM		PACKAGE = Algorithm::AM

BOOT:
  {
    ULONG ten = 10;
    ULONG one = 1;
    ULONG *tensptr = &tens[0];
    ULONG *onesptr = &ones[0];
    unsigned int i;
    for (i = 16; i; i--) {
      *tensptr = ten;
      *onesptr = one;
      ++tensptr;
      ++onesptr;
      ten <<= 1;
      one <<= 1;
    }
  }

  /*
   * This function is called by from Parallel.pm right after creating
   * a blessed reference to Algorithm::AM. It stores the necessary
   * pointers in the AM_GUTS structure and attaches it to the magic
   * part of thre reference.
   *
   */

void
_initialize(...)
 PREINIT:
  HV *project;
  AM_GUTS guts; /* NOT A POINTER THIS TIME! (let memory allocate automatically) */
  SV *svguts;
  MAGIC *mg;
  int i;
 PPCODE:
  project = (HV *) SvRV(ST(0)); /* $self is here */
  guts.activeVar = AvARRAY((AV *) SvRV(ST(1)));
  guts.outcome = AvARRAY((AV *) SvRV(ST(2)));
  guts.itemcontextchain = AvARRAY((AV *) SvRV(ST(3)));
  guts.itemcontextchainhead = (HV *) SvRV(ST(4));
  guts.subtooutcome = (HV *) SvRV(ST(5));
  guts.contextsize = (HV *) SvRV(ST(6));
  guts.pointers = (HV *) SvRV(ST(7));
  guts.gang = (HV *) SvRV(ST(8));
  guts.sum = AvARRAY((AV *) SvRV(ST(9)));
  guts.numoutcomes = av_len((AV *) SvRV(ST(9)));

  /*
   * Since the sublattices are small, we just take a chunk of memory
   * here that will be large enough for our purposes and do the actual
   * memory allocation within the code; this reduces the overhead of
   * repeated system calls.
   *
   */

  for (i = 0; i < 4; ++i) {
    UV v = SvUVX(guts.activeVar[i]);
    Newz(0, guts.lptr[i], 1 << v, USHORT);
    Newz(0, guts.sptr[i], 1 << (v + 1), AM_SUPRA); /* CHANGED */
    Newz(0, guts.sptr[i][0].data, 2, USHORT);
  }

  /* Perl magic invoked here */

  svguts = newSVpv((char *) &guts, sizeof(AM_GUTS));
  sv_magic((SV *) project, svguts, PERL_MAGIC_ext, NULL, 0);
  SvRMAGICAL_off((SV *) project);
  mg = mg_find((SV *) project, PERL_MAGIC_ext);
  mg->mg_virtual = &AMguts_vtab;
  mg_magical((SV *) project);

void
_fillandcount(...)
 PREINIT:
  HV *project;
  AM_GUTS *guts;
  MAGIC *mg;
  USHORT activeVar[4];
  USHORT **lptr;
  AM_SUPRA **sptr;
  USHORT nptr[4];/* this helps us manage the free list in sptr[i] */
  USHORT subcontextnumber;
  USHORT *subcontext;
  USHORT *suboutcome;
  SV **outcome, **itemcontextchain, **sum;
  HV *itemcontextchainhead, *subtooutcome, *contextsize, *pointers, *gang;
  IV numoutcomes;
  HE *he;
  ULONG grandtotal[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  SV *tempsv;
  int chunk, i;
  USHORT gaps[16];
  USHORT *intersect, *intersectlist;
  USHORT *intersectlist2, *intersectlist3, *ilist2top, *ilist3top;
 PPCODE:
  project = (HV *) SvRV(ST(0));
  mg = mg_find((SV *) project, PERL_MAGIC_ext);
  guts = (AM_GUTS *) SvPVX(mg->mg_obj);

  /*
   * We initialize the memory for the sublattices, including setting up the
   * linked lists.
   *
   */

  lptr = guts->lptr;
  sptr = guts->sptr;
  for (chunk = 0; chunk < 4; ++chunk) {
    activeVar[chunk] = (USHORT) SvUVX(guts->activeVar[chunk]);
    Zero(lptr[chunk], 1 << activeVar[chunk], USHORT);
    sptr[chunk][0].next = 0;
    nptr[chunk] = 1;
    for (i = 1; i < 1 << (activeVar[chunk] + 1); ++i) /* CHANGED */
      sptr[chunk][i].next = (USHORT) i + 1;
  }

  /*
   * Instead of adding subcontext labels directly to the supracontexts,
   * we store all of these labels in an array called subcontext.  We
   * then store the array indices of the subcontext labels in the
   * supracontexts.  That means the list of subcontexts in the
   * supracontexts is an increasing sequence of positive integers, handy
   * for taking intersections (see lattice.pod).
   *
   * The index into the array is called subcontextnumber.
   *
   * The array of matching outcomes is called suboutcome.
   *
   */

  subtooutcome = guts->subtooutcome;
  subcontextnumber = (USHORT) HvUSEDKEYS(subtooutcome);
  Newz(0, subcontext, 4 * (subcontextnumber + 1), USHORT);
  subcontext += 4 * subcontextnumber;
  Newz(0, suboutcome, subcontextnumber + 1, USHORT);
  suboutcome += subcontextnumber;
  Newz(0, intersectlist, subcontextnumber + 1, USHORT);
  Newz(0, intersectlist2, subcontextnumber + 1, USHORT);
  ilist2top = intersectlist2 + subcontextnumber;
  Newz(0, intersectlist3, subcontextnumber + 1, USHORT);
  ilist3top = intersectlist3 + subcontextnumber;

  hv_iterinit(subtooutcome);
  while (he = hv_iternext(subtooutcome)) {
    USHORT *contextptr = (USHORT *) HeKEY(he);
    USHORT outcome = (USHORT) SvUVX(HeVAL(he));
    for (chunk = 0; chunk < 4; ++chunk, ++contextptr) {
      USHORT active = activeVar[chunk];
      USHORT *lattice = lptr[chunk];
      AM_SUPRA *supralist = sptr[chunk];
      USHORT nextsupra = nptr[chunk];
      USHORT context = *contextptr;
      AM_SUPRA *p, *c;
      USHORT pi, ci;
      USHORT d, t, tt, numgaps = 0;

      /* We want to add subcontextnumber to the appropriate
       * supracontexts in the four smaller lattices.
       *
       * Suppose we want to add subcontextnumber to the supracontext
       * labeled by d.  supralist[lattice[d]] is an AM_SUPRA which
       * reflects the current state of the supracontext.  Suppose this
       * state is
       *
       * data:    2 0 x y (i.e., currently contains two subcontexts)
       * count:   5
       * next:    7
       * touched: 0
       *
       * Then we pluck an unused AM_SUPRA off of the free list;
       * suppose that it's located at supralist[9] (the variable
       * nextsupra tells us where).  Then supralist[lattice[d]] will
       * change to
       *
       * data:    2 0 x y
       * count:   4 (decrease by 1)
       * next:    9
       * touched: 1
       *
       * and supralist[9] will become
       *
       * data:    3 0 subcontextnumber x y (now has three subcontexts)
       * count:   1
       * next:    7
       * touched: 0
       *
       * (note: the entries in data[] are added in decreasing order)
       *
       *
       * If, on the other hand, if supralist[lattice[d]] looks like
       *
       * data:    2 0 x y
       * count:   8
       * next:    11
       * touched: 1
       *
       * that means that supralist[11] must look something like
       *
       * data:    3 0 subcontextnumber x y
       * count:   4
       * next:    2
       * touched: 0
       *
       * There already exists a supracontext with subcontextnumber
       * added in!  So we change supralist[lattice[d]] to
       *
       * data:    2 0 x y
       * count:   7 (decrease by 1)
       * next:    11
       * touched: 1
       *
       * change supralist[11] to
       *
       * data:    3 0 subcontextnumber x y
       * count:   5 (increase by 1)
       * next:    2
       * touched: 0
       *
       * and set lattice[d] = 11.
       */

      subcontext[chunk] = context;

      if (context == 0) {
	for (p = supralist + supralist->next;
	     p != supralist; p = supralist + p->next) {
	  USHORT *data;
	  Newz(0, data, p->data[0] + 3, USHORT);
	  Copy(p->data + 2, data + 3, p->data[0], USHORT);
	  data[2] = subcontextnumber;
	  data[0] = p->data[0] + 1;
	  Safefree(p->data);
	  p->data = data;
	}
	if (lattice[context] == 0) {

     /* in this case, the subcontext will be
      * added to all supracontexts, so there's
      * no need to hassle with a Gray code and
      * move pointers
      */

	  USHORT count = 0;
	  ci = nptr[chunk];
	  nptr[chunk] = supralist[ci].next;
	  c = supralist + ci;
	  c->next = supralist->next;
	  supralist->next = ci;
	  Newz(0, c->data, 3, USHORT);
	  c->data[2] = subcontextnumber;
	  c->data[0] = 1;
	  for (i = 0; i < (1 << active); ++i) {
	    if (lattice[i] == 0) {
	      lattice[i] = ci;
	      ++count;
	    }
	  }
	  c->count = count;
	}
	continue;
      }

      /* set up traversal using Gray code */
      d = context;
      for (i = 1 << (active - 1); i; i >>= 1)
        if (!(i & context))
	  gaps[numgaps++] = i;
      t = 1 << numgaps;

      p = supralist + (pi = lattice[context]);
      if (pi) --(p->count);
      ci = nextsupra;
      nextsupra = supralist[ci].next;
      p->touched = 1;
      c = supralist + ci;
      c->touched = 0;
      c->next = p->next;
      p->next = ci;
      c->count = 1;
      Newz(0, c->data, p->data[0] + 3, USHORT);
      Copy(p->data + 2, c->data + 3, p->data[0], USHORT);
      c->data[2] = subcontextnumber;
      c->data[0] = p->data[0] + 1;
      lattice[context] = ci;

      /* traverse */
      while (--t) {
   /* find the rightmost 1 in t; from HAKMEM, I believe */
  	for (i = 0, tt = ~t & (t - 1); tt; tt >>= 1, ++i);
  	d ^= gaps[i];

	p = supralist + (pi = lattice[d]);
  	if (pi) --(p->count);
  	switch (p->touched) {
  	case 1:
  	  ++supralist[lattice[d] = p->next].count;
  	  break;
  	case 0:
  	  ci = nextsupra;
  	  nextsupra = supralist[ci].next;
  	  p->touched = 1;
  	  c = supralist + ci;
  	  c->touched = 0;
  	  c->next = p->next;
  	  p->next = ci;
  	  c->count = 1;
  	  Newz(0, c->data, p->data[0] + 3, USHORT);
  	  Copy(p->data + 2, c->data + 3, p->data[0], USHORT);
  	  c->data[2] = subcontextnumber;
  	  c->data[0] = p->data[0] + 1;
  	  lattice[d] = ci;
  	}
      }

      /* Here we return all AM_SUPRA with count 0 back to the free
       * list and set touched = 0 for all remaining.
       */

      p = supralist;
      p->touched = 0;
      do {
        if (supralist[i = p->next].count == 0) {
	  Safefree(supralist[i].data);
  	  p->next = supralist[i].next;
  	  supralist[i].next = nextsupra;
  	  nextsupra = (USHORT) i;
  	} else {
  	  p = supralist + p->next;
  	  p->touched = 0;
  	}
      } while (p->next);
      nptr[chunk] = nextsupra;
    }
    subcontext -= 4;
    *suboutcome = outcome;
    --suboutcome;
    --subcontextnumber;
  }

  contextsize = guts->contextsize;
  pointers = guts->pointers;

  /*
   * The two blocks of code in the if statement are identical except for
   * the counting part -- either pointers or occurrences.  We duplicate
   * the code for speed; nobody wants to be branching all the time.
   *
   * The code is in three parts:
   *
   * 1. We successively take one nonempty supracontext from each of the
   *    four small lattices and take their intersection to find a
   *    supracontext of the big lattice.  If at any point we get the
   *    empty set, we move on.
   *
   * 2. We determine if the supracontext so found is heterogeneous; if
   *    so, we skip it.
   *
   * 3. Otherwise, we count the pointers or occurrences.
   *
   */

  if (SvUVX(ST(1))) {
    /* squared */
    AM_SUPRA *p0, *p1, *p2, *p3;
    USHORT outcome;
    USHORT length;
    unsigned short *temp, *i, *j, *k;

    /* find intersections */
    for (p0 = sptr[0] + sptr[0]->next; p0 != sptr[0]; p0 = sptr[0] + p0->next) {
      for (p1 = sptr[1] + sptr[1]->next; p1 != sptr[1]; p1 = sptr[1] + p1->next) {

	i = p0->data + p0->data[0] + 1;
	j = p1->data + p1->data[0] + 1;
	k = ilist2top;
	while (1) {
	  while (*i > *j) --i;
	  if (*i == 0) break;
	  if (*i < *j) {
	    temp = i;
	    i = j;
	    j = temp;
	    continue;
	  }
	  *k = *i;
	  --i;
	  --j;
	  --k;
	}
	if (k == ilist2top) continue; /* intersection is empty */
	*k = 0;

	for (p2 = sptr[2] + sptr[2]->next; p2 != sptr[2]; p2 = sptr[2] + p2->next) {

	  i = ilist2top;
	  j = p2->data + p2->data[0] + 1;
	  k = ilist3top;
	  while (1) {
	    while (*i > *j) --i;
	    if (*i == 0) break;
	    if (*i < *j) {
	      temp = i;
	      i = j;
	      j = temp;
	      continue;
	    }
	    *k = *i;
	    --i;
	    --j;
	    --k;
	  }
	  if (k == ilist3top) continue; /* intersection is empty */
	  *k = 0;

	  for (p3 = sptr[3] + sptr[3]->next; p3 != sptr[3]; p3 = sptr[3] + p3->next) {
	    outcome = 0;
	    length = 0;
	    intersect = intersectlist;

	    i = ilist3top;
	    j = p3->data + p3->data[0] + 1;
	    while (1) {
	      while (*i > *j) --i;
	      if (*i == 0) break;
	      if (*i < *j) {
		temp = i;
		i = j;
		j = temp;
		continue;
	      }
	      *intersect = *i;
	      ++intersect;
	      ++length;

         /* determine heterogeneity */
	      if (outcome == 0) {
		if (length > 1) {
		  length = 0;
		  break;
		} else {
		  outcome = suboutcome[*i];
		}
	      } else {
		if (outcome != suboutcome[*i]) {
		  length = 0;
		  break;
		}
	      }
	      --i;
	      --j;
	    }

       /* count pointers */
	    if (length) {
	      USHORT i;
	      ULONG pointercount = 0;
	      ULONG count[8] = {0, 0, 0, 0, 0, 0, 0, 0};
	      ULONG mask = 0xffff;

	      count[0]  = p0->count;

	      count[0] *= p1->count;
	      count[1] += count[0] >> 16;
	      count[0] &= mask;

	      count[0] *= p2->count;
	      count[1] *= p2->count;
	      count[1] += count[0] >> 16;
	      count[2] += count[1] >> 16;
	      count[0] &= mask;
	      count[1] &= mask;

	      count[0] *= p3->count;
	      count[1] *= p3->count;
	      count[2] *= p3->count;
	      count[1] += count[0] >> 16;
	      count[2] += count[1] >> 16;
	      count[3] += count[2] >> 16;
	      count[0] &= mask;
	      count[1] &= mask;
	      count[2] &= mask;

	      for (i = 0; i < length; ++i)
		pointercount += (ULONG)
		  SvUV(*hv_fetch(contextsize,
				 (char *) (subcontext + (4 * intersectlist[i])),
				 8, 0));
	      if (pointercount & 0xffff0000) {
		USHORT pchi = (USHORT) (pointercount >> 16);
		USHORT pclo = (USHORT) (pointercount & 0xffff);
		ULONG hiprod[6];
		hiprod[1] = pchi * count[0];
		hiprod[2] = pchi * count[1];
		hiprod[3] = pchi * count[2];
		hiprod[4] = pchi * count[3];
		count[0] *= pclo;
		count[1] *= pclo;
		count[2] *= pclo;
		count[3] *= pclo;
		count[1] += count[0] >> 16;
		count[2] += count[1] >> 16;
		count[3] += count[2] >> 16;
		count[4] += count[3] >> 16;
		count[0] &= mask;
		count[1] &= mask;
		count[2] &= mask;
		count[3] &= mask;
		count[1] += hiprod[1];
		count[2] += hiprod[2];
		count[3] += hiprod[3];
		count[4] += hiprod[4];
		count[2] += count[1] >> 16;
		count[3] += count[2] >> 16;
		count[4] += count[3] >> 16;
		count[5] += count[4] >> 16;
		count[1] &= mask;
		count[2] &= mask;
		count[3] &= mask;
		count[4] &= mask;
	      } else {
		count[0] *= pointercount;
		count[1] *= pointercount;
		count[2] *= pointercount;
		count[3] *= pointercount;
		count[1] += count[0] >> 16;
		count[2] += count[1] >> 16;
		count[3] += count[2] >> 16;
		count[4] += count[3] >> 16;
		count[0] &= mask;
		count[1] &= mask;
		count[2] &= mask;
		count[3] &= mask;
	      }
	      for (i = 0; i < length; ++i) {
		int j;
		SV *tempsv;
		ULONG *p;
		tempsv = *hv_fetch(pointers,
				   (char *) (subcontext + (4 * intersectlist[i])),
				   8, 1);
		if (!SvPOK(tempsv)) {
		  SvUPGRADE(tempsv, SVt_PVNV);
		  SvGROW(tempsv, 8 * sizeof(ULONG) + 1);
		  Zero(SvPVX(tempsv), 8, ULONG);
		  SvCUR_set(tempsv, 8 * sizeof(ULONG));
		  SvPOK_on(tempsv);
		}
		p = (ULONG *) SvPVX(tempsv);
		for (j = 0; j < 7; ++j) {
		  *(p + j) += count[j];
		  *(p + j + 1) += *(p + j) >> 16;
		  *(p + j) &= mask;
		}
	      }
	    }
	  }
	}
      }
    }
    /* clear out the supracontexts */
    for (p0 = sptr[0] + sptr[0]->next; p0 != sptr[0]; p0 = sptr[0] + p0->next)
      Safefree(p0->data);
    for (p1 = sptr[1] + sptr[1]->next; p1 != sptr[1]; p1 = sptr[1] + p1->next)
      Safefree(p1->data);
    for (p2 = sptr[2] + sptr[2]->next; p2 != sptr[2]; p2 = sptr[2] + p2->next)
      Safefree(p2->data);
    for (p3 = sptr[3] + sptr[3]->next; p3 != sptr[3]; p3 = sptr[3] + p3->next)
      Safefree(p3->data);
  }
  else
  {
    /* linear */
    AM_SUPRA *p0, *p1, *p2, *p3;
    USHORT outcome;
    USHORT length;
    unsigned short *temp, *i, *j, *k;

    /* find intersections */
    for (p0 = sptr[0] + sptr[0]->next; p0 != sptr[0]; p0 = sptr[0] + p0->next) {
      for (p1 = sptr[1] + sptr[1]->next; p1 != sptr[1]; p1 = sptr[1] + p1->next) {

	i = p0->data + p0->data[0] + 1;
	j = p1->data + p1->data[0] + 1;
	k = ilist2top;
	while (1) {
	  while (*i > *j) --i;
	  if (*i == 0) break;
	  if (*i < *j) {
	    temp = i;
	    i = j;
	    j = temp;
	    continue;
	  }
	  *k = *i;
	  --i;
	  --j;
	  --k;
	}
	if (k == ilist2top) continue; /* intersection is empty */
	*k = 0;

	for (p2 = sptr[2] + sptr[2]->next; p2 != sptr[2]; p2 = sptr[2] + p2->next) {

	  i = ilist2top;
	  j = p2->data + p2->data[0] + 1;
	  k = ilist3top;
	  while (1) {
	    while (*i > *j) --i;
	    if (*i == 0) break;
	    if (*i < *j) {
	      temp = i;
	      i = j;
	      j = temp;
	      continue;
	    }
	    *k = *i;
	    --i;
	    --j;
	    --k;
	  }
	  if (k == ilist3top) continue; /* intersection is empty */
	  *k = 0;

	  for (p3 = sptr[3] + sptr[3]->next; p3 != sptr[3]; p3 = sptr[3] + p3->next) {
	    outcome = 0;
	    length = 0;
	    intersect = intersectlist;

	    i = ilist3top;
	    j = p3->data + p3->data[0] + 1;
	    while (1) {
	      while (*i > *j) --i;
	      if (*i == 0) break;
	      if (*i < *j) {
		temp = i;
		i = j;
		j = temp;
		continue;
	      }
	      *intersect = *i;
	      ++intersect;
	      ++length;

         /* determine heterogeneity */
	      if (outcome == 0) {
		if (length > 1) {
		  length = 0;
		  break;
		} else {
		  outcome = suboutcome[*i];
		}
	      } else {
		if (outcome != suboutcome[*i]) {
		  length = 0;
		  break;
		}
	      }
	      --i;
	      --j;
	    }

       /* count occurrences */
	    if (length) {
	      USHORT i;
	      ULONG count[8] = {0, 0, 0, 0, 0, 0, 0, 0};
	      ULONG mask = 0xffff;

	      count[0]  = p0->count;

	      count[0] *= p1->count;
	      count[1] += count[0] >> 16;
	      count[0] &= mask;

	      count[0] *= p2->count;
	      count[1] *= p2->count;
	      count[1] += count[0] >> 16;
	      count[2] += count[1] >> 16;
	      count[0] &= mask;
	      count[1] &= mask;

	      count[0] *= p3->count;
	      count[1] *= p3->count;
	      count[2] *= p3->count;
	      count[1] += count[0] >> 16;
	      count[2] += count[1] >> 16;
	      count[3] += count[2] >> 16;
	      count[0] &= mask;
	      count[1] &= mask;
	      count[2] &= mask;

	      for (i = 0; i < length; ++i) {
		int j;
		SV *tempsv;
		ULONG *p;
		tempsv = *hv_fetch(pointers,
				   (char *) (subcontext + (4 * intersectlist[i])),
				   8, 1);
		if (!SvPOK(tempsv)) {
		  SvUPGRADE(tempsv, SVt_PVNV);
		  SvGROW(tempsv, 8 * sizeof(ULONG) + 1);
		  Zero(SvPVX(tempsv), 8, ULONG);
		  SvCUR_set(tempsv, 8 * sizeof(ULONG));
		  SvPOK_on(tempsv);
		}
		p = (ULONG *) SvPVX(tempsv);
		for (j = 0; j < 7; ++j) {
		  *(p + j) += count[j];
		  *(p + j + 1) += *(p + j) >> 16;
		  *(p + j) &= mask;
		}
	      }
	    }
	  }
	}
      }
    }
    /* clear out the supracontexts */
    for (p0 = sptr[0] + sptr[0]->next; p0 != sptr[0]; p0 = sptr[0] + p0->next)
      Safefree(p0->data);
    for (p1 = sptr[1] + sptr[1]->next; p1 != sptr[1]; p1 = sptr[1] + p1->next)
      Safefree(p1->data);
    for (p2 = sptr[2] + sptr[2]->next; p2 != sptr[2]; p2 = sptr[2] + p2->next)
      Safefree(p2->data);
    for (p3 = sptr[3] + sptr[3]->next; p3 != sptr[3]; p3 = sptr[3] + p3->next)
      Safefree(p3->data);
  }

  /*
   * compute analogical set and gang effects
   *
   * Technically, we don't compute the analogical set; instead, we
   * compute how many pointers/occurrences there are for each of the
   * data items in a particular subcontext, and associate that number
   * with the subcontext label, not directly with the data item.  We can
   * do this because if two data items are in the same subcontext, they
   * will have the same number of pointers/occurrences.
   *
   * If the user wants the detailed analogical set, it will be created
   * in Parallel.pm.
   *
   */

  gang = guts->gang;
  outcome = guts->outcome;
  itemcontextchain = guts->itemcontextchain;
  itemcontextchainhead = guts->itemcontextchainhead;
  sum = guts->sum;
  numoutcomes = guts->numoutcomes;
  hv_iterinit(pointers);
  while (he = hv_iternext(pointers)) {
    ULONG count;
    USHORT counthi, countlo;
    ULONG p[8];
    ULONG gangcount[8];
    USHORT thisoutcome;
    SV *dataitem;
    Copy(SvPVX(HeVAL(he)), p, 8, ULONG);
    tempsv = *hv_fetch(contextsize, HeKEY(he), 4 * sizeof(USHORT), 0);
    count = (ULONG) SvUVX(tempsv);
    counthi = (USHORT) (count >> 16);
    countlo = (USHORT) (count & 0xffff);
    gangcount[0] = 0;
    for (i = 0; i < 6; ++i) {
      gangcount[i] += countlo * p[i];
      gangcount[i + 1] = gangcount[i] >> 16;
      gangcount[i] &= 0xffff;
    }
    if (counthi) {
      for (i = 0; i < 6; ++i) {
	gangcount[i + 1] += counthi * p[i];
	gangcount[i + 2] += gangcount[i + 1] >> 16;
	gangcount[i + 1] &= 0xffff;
      }
    }
    for (i = 0; i < 7; ++i) {
      grandtotal[i] += gangcount[i];
      grandtotal[i + 1] += grandtotal[i] >> 16;
      grandtotal[i] &= 0xffff;
    }
    grandtotal[7] += gangcount[7];
    tempsv = *hv_fetch(gang, HeKEY(he), 4 * sizeof(USHORT), 1);
    SvUPGRADE(tempsv, SVt_PVNV);
    sv_setpvn(tempsv, (char *) gangcount, 8 * sizeof(ULONG));
    normalize(tempsv);
    normalize(HeVAL(he));

    tempsv = *hv_fetch(subtooutcome, HeKEY(he), 4 * sizeof(USHORT), 0);
    thisoutcome = (USHORT) SvUVX(tempsv);
    if (thisoutcome) {
      ULONG *s = (ULONG *) SvPVX(sum[thisoutcome]);
      for (i = 0; i < 7; ++i) {
	*(s + i) += gangcount[i];
	*(s + i + 1) += *(s + i) >> 16;
	*(s + i) &= 0xffff;
      }
    } else {
      dataitem = *hv_fetch(itemcontextchainhead, HeKEY(he), 4 * sizeof(USHORT), 0);
      while (SvIOK(dataitem)) {
	IV datanum = SvIVX(dataitem);
	IV ocnum = SvIVX(outcome[datanum]);
	ULONG *s = (ULONG *) SvPVX(sum[ocnum]);
	for (i = 0; i < 7; ++i) {
	  *(s + i) += p[i];
	  *(s + i + 1) += *(s + i) >> 16;
	  *(s + i) &= 0xffff;
	  dataitem = itemcontextchain[datanum];
	}
      }
    }
  }
  for (i = 1; i <= numoutcomes; ++i) normalize(sum[i]);
  tempsv = *hv_fetch(pointers, "grandtotal", 10, 1);
  SvUPGRADE(tempsv, SVt_PVNV);
  sv_setpvn(tempsv, (char *) grandtotal, 8 * sizeof(ULONG));
  normalize(tempsv);

  Safefree(subcontext);
  Safefree(suboutcome);
  Safefree(intersectlist);
  Safefree(intersectlist2);
  Safefree(intersectlist3);